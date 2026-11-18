# Making changes safely

Read this before changing configuration. The recipes below are the reversible
way to do common jobs; the last section lists the operations where a mistake is
expensive or permanent.

The general shape of a safe change: know the current state, write down how to get
back to it, make the smallest change that achieves the goal, verify it, and tell
the user what actually happened.

```bash
qm config <id> > /root/backup-<id>-$(date +%F).conf      # cheap insurance
cp /etc/network/interfaces /root/interfaces.$(date +%F)  # before network edits
```

## Contents

- [Guests](#guests)
- [Storage](#storage)
- [Network](#network)
- [Backup jobs](#backup-jobs)
- [Testing a restore](#testing-a-restore)
- [Users and permissions](#users-and-permissions)
- [Operations that deserve extra care](#operations-that-deserve-extra-care)
- [Verifying afterwards](#verifying-afterwards)

## Guests

```bash
# inspect first
qm config <id> ; pct config <id>

# snapshot before anything risky (instant on ZFS)
qm snapshot <id> before-change --description "before X"
pct snapshot <id> before-change
qm rollback <id> before-change        # the way back
qm delsnapshot <id> before-change     # clean up once satisfied

# change settings - never by editing the .conf directly
qm set <id> --memory 8192
qm set <id> --cores 4
pct set <id> --memory 2048 --cores 2
pct set <id> --mp0 /tank/data,mp=/data      # bind mount into a container

# disks
qm disk resize <id> scsi0 +10G        # grow only; shrinking is not supported
pct resize <id> rootfs +5G
qm disk move <id> scsi0 <targetstorage> --delete 0   # keep the source until verified

# lifecycle
pct create <id> <template> --hostname x --storage <s> --net0 name=eth0,bridge=vmbr0,ip=dhcp
qm clone <src> <newid> --name x --full 1
qm unlock <id> ; pct unlock <id>      # only after confirming no task is running
```

Notes that matter in practice:

- **Growing a disk is easy, shrinking is not supported.** Add space in small
  steps rather than one large guess.
- **`--delete 0` when moving a disk** leaves the original in place until you have
  confirmed the guest boots from the new copy. Remove the leftover afterwards, or
  it quietly consumes the old storage forever.
- **Unprivileged containers map UIDs**, so files created inside land as high UIDs
  on the host. Bind-mount permission problems nearly always come from this;
  `python3 <skill-dir>/scripts/docs.py search unprivileged container bind mount` has the mapping rules.
  The default offset is 100000 (`/etc/subuid`), so a host directory owned by
  `100501:100401` appears inside the container as uid 501, gid 401. Read the
  host ownership first and match it, rather than loosening permissions until it
  works. Three things regularly bite here:
  - When several guests share one directory, give the shared group the **setgid
    bit** (`chmod 2775`) so new files keep that group instead of the creator's
    primary group - otherwise the other containers silently lose access.
  - **ACLs need `acltype=posixacl`** on the ZFS dataset; where it is `off`,
    `setfacl` is not an option and group ownership plus setgid is the only route.
  - PVE 9.2 added a per-mountpoint `idmap=` option (unprivileged containers
    only), which maps one specific UID instead of restructuring groups.
    Useful, but it diverges from however the rest of the host is set up -
    prefer consistency unless there is a reason.
- **Bind mount contents are excluded from vzdump and PBS.** Guest disks on a
  storage are backed up; a bind-mounted host directory is not, at all. If data
  needs to survive, it needs its own arrangement (`zfs send`, a backup client
  inside the guest, or a replica) - or put it on a storage-backed mount point
  with `backup=1`, which is included. The GUI sets `backup=1` on new mount
  points; `pct set` does not.
- **Changing a container's hostname** takes effect on its next restart; network
  interfaces, memory and cores are changed live.

## Storage

```bash
pvesm status
pvesm add <type> <name> --path /mnt/x --content images,rootdir,backup
pvesm set <name> --content backup,iso
pvesm set <name> --disable 1          # take out of use without deleting anything
pvesm remove <name>                   # removes the definition, not the data
```

`pvesm remove` only forgets the storage; the data stays on disk. That makes it a
safe first step when retiring a storage - remove the definition, confirm nothing
broke, and clean up the data later.

The `content` types decide what may live there (`images`, `rootdir`, `vztmpl`,
`backup`, `iso`, `snippets`). A storage that "cannot hold" a disk is almost
always a content-type mismatch rather than a fault.

## Network

Network changes are the most common way to lose access to a host, so:

1. Make sure there is a second way in first - the other node, IPMI/iKVM, or a
   physical console. On a two-node cluster the other node is usually enough.
2. Edit `/etc/network/interfaces` directly, or use the GUI, which stages its
   changes in `/etc/network/interfaces.new`.
3. Apply. Direct edits: `ifreload -a`. Staged GUI changes: Apply Configuration
   in the GUI, or a reboot - `ifreload -a` alone does not read
   `interfaces.new`.
4. Verify from a *new* connection before closing the working one.

```bash
cat /etc/network/interfaces
ifreload -a -n            # dry run: parse and show what would change
ifreload -a               # apply
```

**Read the whole file before reloading, not just your own edit.** `ifreload -a`
re-applies *every* stanza, including ones that have been inert since the last
boot. A config where an interface is claimed twice - say `eno1` carrying
`bond-master bond0` while `vmbr0` lists it under `bridge-ports` - keeps working
indefinitely because only one claim was ever enacted. The reload then enacts the
other one, and the uplink disappears while you are holding an unrelated change
in your hand. `check.sh --section network` reports these conflicts; resolve
them first, and treat the dry run's output as something to actually read rather
than a formality.

For a bridge, the physical interface belongs in `bridge-ports`; the IP belongs on
the bridge, not on the physical port. VLAN-aware bridges (`bridge-vlan-aware yes`)
let guests pick their own VLAN tag, which is usually what you want rather than a
bridge per VLAN.

## Backup jobs

```bash
cat /etc/pve/jobs.cfg
# add or edit via the GUI (Datacenter > Backup) or:
pvesh create /cluster/backup --schedule "02:00" --storage <s> --mode snapshot --all 1
pvesh set /cluster/backup/<job-id> --schedule "03:30"
vzdump <id> --storage <s> --mode snapshot     # one-off, run it before risky work
```

A backup job is only real once a run has succeeded and a restore has been tried.
When you set one up, check the first execution rather than assuming the schedule
works, and confirm retention (`prune-backups`) so the target does not fill.

## Testing a restore

A backup is only proven by a restore. The test restores a copy next to the
original, keeps it off the network, checks it, and removes it. It writes (a new
guest, new volumes), so propose it in the usual shape first; the original guest
is never touched.

```bash
# read-only: pick the backup, a free ID and a storage with room
pvesm list <backup-storage> --vmid <id>        # volid of the newest backup
pvesm extractconfig <volid>                    # what the restore will recreate
pvesh get /cluster/nextid                      # free ID, e.g. 9001
pvesm status                                   # target storage and its free space

# VM: --unique 1 gives new MAC addresses; the restore does not start it
qmrestore <volid> <newid> --storage <s> --unique 1
qm set <newid> --onboot 0 --name restoretest-<id>
qm set <newid> --net0 <model>,bridge=<bridge>,link_down=1   # copy net0 from 'qm config', add link_down=1, per netX

# container: --unique 1 likewise; it does not start unless --start 1 is given
pct restore <newid> <volid> --storage <s> --unique 1
pct set <newid> --onboot 0 --hostname restoretest-<id>
pct set <newid> --net0 name=eth0,bridge=<bridge>,link_down=1   # per netX, from 'pct config'
pct config <newid> | grep -E '^mp[0-9]+: /'    # bind mounts came back - remove each:
pct set <newid> --delete mp<N>

# verify
qm start <newid>   ; qm terminal <newid> / the console      # boots, services start, data is there
pct start <newid>  ; pct enter <newid>

# clean up - check the ID twice: destroy has no undo
qm stop <newid>  ; qm destroy <newid> --purge
pct stop <newid> ; pct destroy <newid> --purge
```

What to watch:

- **Bind mounts come back with the restore.** `pct restore` re-adds bind and
  device mount points to the restored config (without content - they are never
  backed up). A test container started with them sees, and can write to, the
  live host data. Remove them before the first start.
- **Same addresses, same names.** A restored guest carries the original's static
  IPs and hostname; `link_down=1` on every interface keeps it from colliding with
  the original, `--unique 1` avoids duplicate MAC addresses.
- **Passed-through devices** (`hostpci`, `usb`) in a VM config point at hardware
  the original is using; remove them from the copy before starting it.
- **Space.** The copy needs as much room as the original's disks on the target
  storage; on a nearly full pool pick another storage or a smaller guest.
- **Live-restore** (`qmrestore --live-restore 1`, PBS only) starts the VM while
  data still streams in; for a test the plain restore is the clearer proof.

## Users and permissions

```bash
pveum user list ; pveum role list
pveum user add someone@pve --password ...
pveum acl modify / --users someone@pve --roles PVEAuditor
pveum acl list
```

Prefer a narrow role on a narrow path over `Administrator` on `/`. `PVEAuditor`
is the right level for anything that only needs to look.

## Operations that deserve extra care

- **Removing a node from a cluster (`pvecm delnode`) is not reversible.** A
  removed node must never be powered back on with its old identity, and its name
  cannot simply be reused - reinstall it first. Move all guests off, verify
  backups, and confirm the remaining nodes keep quorum before starting.
- **`pvecm expected 1`** overrides quorum on a survivor. It is the correct tool
  when the other node is genuinely gone, and a way to create split-brain when it
  is not. Undo it once membership returns.
- **Destroying a guest (`qm destroy` / `pct destroy`)** removes its disks. Confirm
  a backup exists and that the ID is the one the user meant - IDs are easy to
  mistype and there is no undo.
- **`zpool` operations that change vdevs** (replace, remove, attach) rewrite pool
  topology; get the device path from `/dev/disk/by-id/` and read the docs for the
  exact pool layout first.
- **Restoring over an existing guest** overwrites it. Restore to a new ID when
  the goal is to compare or recover a file.
- **Editing `/etc/pve` by hand** while the cluster is not quorate, or on two
  nodes at once, produces conflicts the database resolves in ways nobody
  predicted.

## Verifying afterwards

Say what you checked, not just what you ran:

```bash
qm config <id> | grep <the changed key>
pvesm status
systemctl is-active <service>
bash <skill-dir>/scripts/check.sh --section <area>
```

If a change did not have the intended effect, say so and stop rather than
layering another change on top of an unclear state.
