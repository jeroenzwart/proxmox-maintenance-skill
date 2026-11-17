# Diagnosing a Proxmox host

Read this when something is broken. It maps symptoms to the places that actually
hold the answer, so you spend your first minutes reading evidence instead of
guessing.

Two habits that pay for themselves on every incident:

**Find the task log.** Almost everything in PVE runs as a task with a UPID, and
the task log contains the real error - the GUI and the CLI usually show only the
last line of it.

```bash
pvenode task list --limit 20            # recent tasks with status
pvenode task log <UPID>                 # the full output of one task
```

**Follow the service that owns the subsystem**, rather than reading all of
journald: `pve-cluster` (the `/etc/pve` filesystem), `corosync` (membership),
`pvedaemon`/`pveproxy` (API and web UI), `pvestatd` (the statistics that feed the
GUI), `pvescheduler` (backup and replication jobs).

```bash
journalctl -u pvestatd --since '1 hour ago' --no-pager
journalctl -b -p err --no-pager | tail -40
```

## Contents

- [A guest will not start](#a-guest-will-not-start)
- [Storage is inactive, full, or gone](#storage-is-inactive-full-or-gone)
- [ZFS trouble](#zfs-trouble)
- [Cluster and quorum](#cluster-and-quorum)
- [Network](#network)
- [Backups fail](#backups-fail)
- [Web UI or API unreachable](#web-ui-or-api-unreachable)
- [Performance complaints](#performance-complaints)

## A guest will not start

```bash
qm start 101                      # VM: run it in the foreground, read the error
pct start 101 --debug             # container: verbose startup
qm config 101 ; pct config 101    # what is actually configured
pvenode task list --limit 10
```

Causes, roughly in order of how often they turn out to be the real one:

- **A stale `lock:` in the config.** A backup, migration or snapshot died and
  left the guest locked. Confirm nothing is still running (`qm status`, check for
  a running vzdump task), then `qm unlock <id>` / `pct unlock <id>`.
- **Its storage is not available.** The config references a storage that is
  inactive or a volume that no longer exists: `pvesm status`, then
  `pvesm list <storage>`. Common after a disk swap or a renamed pool.
- **Not enough memory**, or ballooning limits: the task log says so plainly.
- **A passed-through device is missing** (PCIe, USB, a mount point on the host).
  Hardware IDs move when slots or disks change.
- **Container-specific**: an unprivileged container failing on permissions of a
  bind mount, or a template/OS mismatch after a host upgrade. `pct mount <id>`
  lets you inspect its filesystem from the host without booting it - remember
  `pct unmount <id>` afterwards.
- **A config that references a node that no longer exists**, typically a leftover
  under `/etc/pve/nodes/<stale>/`.

Docs: `python3 <skill-dir>/scripts/pve-docs.py search qm start troubleshooting`, `python3 <skill-dir>/scripts/pve-docs.py search pct configuration`.

## Storage is inactive, full, or gone

```bash
pvesm status                      # per-storage state and usage
cat /etc/pve/storage.cfg          # how it is defined (cluster-wide)
pvesm list <storage>              # volumes it holds
df -h ; lsblk -f
```

- **Inactive**: for network storage (NFS, CIFS, PBS) this is nearly always
  reachability - the server, the network, or credentials. Test the underlying
  transport directly before touching PVE config.
- **A storage defined for the wrong node**: `storage.cfg` entries can be limited
  with `nodes=`; a storage that exists on one node and not another is usually
  this, not a fault.
- **Full**: check what fills it. Old backups (`vzdump` retention), orphaned disk
  images from deleted guests (`pvesm list` versus the guest configs), snapshots
  that were never removed. On the root filesystem, `/var/log` and
  `/var/lib/vz/dump` are the usual suspects.
- **A full root filesystem breaks things far from storage** - the API, the
  cluster filesystem, logging - so treat it as urgent even when the user's
  complaint sounds unrelated.

## ZFS trouble

```bash
zpool status -v                   # errors per vdev, with affected files
zpool list -o name,size,alloc,free,frag,cap,health
zpool events -v | tail -30        # what actually happened, with timestamps
zfs list -o name,used,avail,refer,mountpoint
smartctl -a /dev/sdX              # the disk's own opinion
```

Reading `zpool status`: the READ/WRITE/CKSUM columns are error counters per
device. Non-zero **checksum** errors mean data was returned wrong and ZFS
corrected it - the disk or the cable is lying. Non-zero **write** errors point at
a disk or controller failing to accept data. A disk can report `PASSED` in SMART
while ZFS records hundreds of errors against it; ZFS sees the corruption SMART's
self-assessment does not.

- **DEGRADED**: a device dropped out. Identify it by its `/dev/disk/by-id/` name
  (which is stable, unlike `/dev/sdX`), then follow the replacement procedure in
  the docs: `python3 <skill-dir>/scripts/pve-docs.py search zfs replace failed device`.
- **Errors but ONLINE**: run a scrub to find out how far the damage goes
  (`zpool scrub <pool>`), and check cabling and the controller before blaming the
  disk - especially when several disks report errors at once.
- **Pool full**: ZFS slows dramatically above ~80% and refuses writes near 100%.
  Snapshots hold space invisibly: `zfs list -t snapshot -o name,used -s used`.
- **Pool missing after boot**: usually an import problem (`zpool import` shows
  what is available) or a cache-file issue.

Note that `pool` capacity in `zpool list` and the free space PVE reports differ
for ZVOLs and refreservations - that is expected, not a bug.

## Cluster and quorum

```bash
pvecm status ; pvecm nodes
corosync-cfgtool -s               # link state per node
journalctl -u corosync -u pve-cluster --since '1 hour ago' --no-pager
systemctl status pve-cluster
```

- **`/etc/pve` read-only** means quorum is lost. Nothing that writes cluster
  config will work until it returns. Fix membership first; do not work around it.
- **Two-node clusters** lose quorum whenever one node is down - that is the
  design, not a fault. `pvecm expected 1` forces the survivor to continue, but it
  invites split-brain: only use it deliberately, while the other node is truly
  off, and undo it once membership is restored.
- **A node shows as offline while it is up**: corosync traffic is not arriving.
  Look at MTU, a switch that lost multicast/unicast paths, a changed IP, or a
  firewall. `corosync-cfgtool -s` tells you which link is down.
- **Time drift** between nodes breaks certificates and confuses logs. Check
  `chronyc tracking` on each node.
- **`pmxcfs` errors** in the log usually accompany a full root filesystem or a
  corrupted local database; the config database lives at
  `/var/lib/pve-cluster/config.db`.

## Network

```bash
ip -brief address ; ip -brief link
cat /etc/network/interfaces
bridge link show
ethtool <iface> | grep -E 'Speed|Duplex|Link detected'
```

- **`/etc/network/interfaces.new` exists**: a change is staged but not applied.
  It takes effect on reboot or via Apply Configuration in the GUI.
- **Guests lose connectivity after a host change**: check that the bridge still
  has the physical uplink as a member, and that VLAN awareness matches what the
  guests expect.
- **Interface names changed after a hardware or kernel change** - this silently
  breaks bridges. `pve-network-interface-pinning generate` pins the names for
  exactly this; the pinned names take effect after a reboot.
- **A guest interface but no traffic**: with the PVE firewall enabled each guest
  gets `fwbr`/`fwpr`/`veth` devices; check `pve-firewall status` and the guest's
  firewall rules before suspecting the bridge.

## Backups fail

```bash
cat /etc/pve/jobs.cfg              # scheduled jobs
grep vzdump /var/log/pve/tasks/index | tail -20
pvenode task log <UPID>            # the failing run
pvesm status                       # is the target storage active
```

- **PBS-specific**: fingerprint mismatch after the PBS server was reinstalled,
  an expired or changed API token, a datastore that is full, or a prune/GC job
  that never runs so the datastore fills up over time.
- **`vzdump` snapshot mode failing** on a guest whose storage does not support
  snapshots - the mode fell back or errored; `python3 <skill-dir>/scripts/pve-docs.py search backup modes`
  explains the guarantees of each mode.
- **A backup that hangs** usually means a guest that will not quiesce (qemu-guest-agent
  missing or unresponsive) or a slow target; the task log shows where it stopped.
- **Silent non-execution**: a job whose schedule never matched, or `pvescheduler`
  not running. A backup nobody checks is not a backup - verify the last run, not
  just the job definition.

## Web UI or API unreachable

```bash
systemctl status pveproxy pvedaemon pve-cluster
journalctl -u pveproxy --since '30 min ago' --no-pager
openssl x509 -enddate -noout -in /etc/pve/local/pveproxy-ssl.pem
ss -tlnp | grep 8006
```

Common causes: an expired certificate, a full root filesystem, `pve-cluster` down
(so `/etc/pve` is empty and pveproxy cannot read its config), or a custom
certificate whose key does not match. `pvecm updatecerts --force` generates new
cluster-internal certificates when they are the problem; without `--force` it
only fills in missing files.

## Performance complaints

```bash
pveperf                            # quick baseline of the host
top -b -n1 | head -20 ; iostat -x 2 3
qm status <id> --verbose
arcstat 1 5                        # ZFS ARC hit rate
zpool iostat -v 2 3
```

Look for: ZFS ARC starved because guests were given all the RAM (ZFS wants
memory, and its default limit may not match how the host is now used); a pool
above 80% capacity; ballooning shrinking a VM; a single guest saturating the
disks; or CPU steal from oversubscription. Establish which layer is slow before
tuning anything - host, storage, guest, and network each look the same from
inside the VM.
