---
name: proxmox-maintenance
description: >-
  Maintenance of Proxmox hosts - Proxmox VE (PVE), Proxmox Backup Server (PBS)
  and Proxmox Datacenter Manager (PDM): health checks, diagnosing failures,
  safe configuration changes, and updates or version upgrades, grounded in the
  version-matched docs installed on the host. Use it whenever the user
  mentions Proxmox, PVE, PBS, PDM, a node or cluster, corosync/quorum, LXC
  containers or VMs (pct/qm), /etc/pve, ZFS pools, vzdump, datastores, prune,
  garbage collection, verify or sync jobs, remotes or fingerprints, or asks
  about updating, rebooting, troubleshooting or changing these hosts, in
  whatever language they write. Use it too for symptoms that prove
  Proxmox-side: a guest that will not start, storage shown as inactive, a node
  dropped from the cluster, a failed backup or a full datastore, a remote
  shown as unavailable, an unreachable web UI, a disk throwing errors. Not for
  work inside a guest, such as configuring an app in a container, nor for
  storage on separate appliances such as a Synology or TrueNAS.
allowed-tools: Bash(bash ${CLAUDE_SKILL_DIR}/scripts/check.sh*) Bash(python3 ${CLAUDE_SKILL_DIR}/scripts/docs.py status*) Bash(python3 ${CLAUDE_SKILL_DIR}/scripts/docs.py search*) Bash(python3 ${CLAUDE_SKILL_DIR}/scripts/docs.py show*) Bash(python3 ${CLAUDE_SKILL_DIR}/scripts/docs.py --product*)
---

# Proxmox maintenance

This skill exists because a Proxmox host is not an ordinary Linux box. A
careless command on a hypervisor breaks every service running on it; on a
backup server it can cost the only copy of something; on a datacenter manager
it reaches into every cluster it manages. So the working style is: **look
first, read the manual for this exact version, propose, then act only with a
go-ahead.**

Answer the user in their own language; keep command names, log lines and config
keys in their original form.

This skill lives in `${CLAUDE_SKILL_DIR}`, so its paths resolve wherever it is
installed. The reference files write that directory as `<skill-dir>`; fill in
`${CLAUDE_SKILL_DIR}` when running their commands.

## 1. Orient before anything else

Never diagnose from assumptions about how the host is set up - ask the machine.

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/check.sh               # ~30s, read-only, whole host
bash ${CLAUDE_SKILL_DIR}/scripts/check.sh --products    # which products are installed
bash ${CLAUDE_SKILL_DIR}/scripts/check.sh --full        # + the last 24h of journal errors
bash ${CLAUDE_SKILL_DIR}/scripts/check.sh --product pbs # host-level + one product
bash ${CLAUDE_SKILL_DIR}/scripts/check.sh --section zfs # one area only
bash ${CLAUDE_SKILL_DIR}/scripts/check.sh --cluster     # PVE: + the other nodes over SSH
```

The check detects which of PVE, PBS and PDM are installed and lists them with
their versions in its first block. It then prints host-level sections
(identity, services, packages, certs, network, zfs, disk, smart) and the
sections of each installed product:

| Product | Sections |
|---|---|
| PVE | cluster, storage, guests, backup |
| PBS | datastores, gc, jobs, tasks, remotes, tape |
| PDM | remotes, subscriptions |

Problems are marked with `!!`. Everything in it only observes; it starts,
stops, installs and writes nothing, so it is always safe to run first. Inside
a container it skips what belongs to the host (disks, pools, kernel).

Read the `!!` lines before answering. They frequently explain the user's actual
question - a container that will not start because a stale `lock:` sits in its
config, storage "gone" because a pool is degraded, an upgrade that behaves oddly
because a repository still points at the previous Debian release.

For a narrow, well-understood question, `--section` is enough; do not run the
full sweep when the user asked one small thing.

## 2. What to carry into any answer

These findings change what a plan should look like. Mention them whenever the
check surfaces them, even if the user asked about something else.

**Any host**

- **A degraded pool** means the next disk failure is not a scare but a loss, and
  it makes reboots and resilvers risky. Say how much redundancy is actually left.
- **A conflicting network definition is a delayed-action fault.** Where an
  interface is claimed by both a bond and a bridge, the config works until
  something reloads it - and then the uplink can vanish during a change that had
  nothing to do with it. Check this before proposing any network apply, and
  prefer bringing up the single interface you added (`ifup <iface>`) over
  reloading everything.

**PVE**

- **Bind mounts are not in any vzdump/PBS backup.** A nightly job reporting OK
  covers the guests, not the host directories mounted into them - which is
  usually where the bulk of the irreplaceable data sits. Never call data "backed
  up" without checking which of the two it is.
- **Node-restricted storages pin their guests.** A guest using one cannot
  migrate or be restored elsewhere, so "migrate it off first" may simply not be
  available when planning a reboot.

**PBS**

- **Prune frees nothing until garbage collection runs.** Prune only removes
  snapshot references; GC deletes the chunks. A datastore that keeps filling
  despite prune jobs usually has no working GC schedule.
- **GC relies on access times.** It only removes chunks whose atime is older
  than about 24 hours, so the datastore filesystem must keep atime or relatime.
- **A certificate change breaks every client that pinned the old
  fingerprint** - the PBS storage entry on PVE hosts and sync remotes alike.
  `proxmox-backup-manager cert info` shows the current fingerprint.

**PDM**

- **Remotes are pinned by fingerprint.** When a remote renews its certificate,
  PDM loses it until the fingerprint is probed and updated.
- **An unreachable remote is usually a remote problem**: the host, the network
  or a revoked API token, not PDM itself.
- **The enterprise repository needs 80% subscribed remote nodes** (Basic or
  higher); PDM has no subscription of its own.

## 3. Read the documentation for *this* version

Every product ships its complete manual on the host, and apt keeps it in step
with the installed version: `pve-docs` for PVE, `proxmox-backup-docs` for PBS,
`proxmox-datacenter-manager-docs` for PDM. That local copy is the
authoritative manual for this machine - more trustworthy than memory, which
ages badly across Proxmox releases.

```bash
python3 ${CLAUDE_SKILL_DIR}/scripts/docs.py status                  # versions + index state
python3 ${CLAUDE_SKILL_DIR}/scripts/docs.py search zfs replace failed disk -n 5
python3 ${CLAUDE_SKILL_DIR}/scripts/docs.py --product pbs search garbage collection
python3 ${CLAUDE_SKILL_DIR}/scripts/docs.py show 'chapter-sysadmin#sysadmin_zfs_change_failed_dev'
```

Without `--product` it covers every installed product; with more than one, ids
carry a product prefix (`pbs:maintenance#pruning`). `search` rebuilds its index
automatically when the product or docs version has changed, so it is always
the manual for the running release. Cite the section id you used when you give
advice based on it - that lets the user verify the claim instead of trusting
it.

Consult the docs whenever the task is more than a one-liner you are certain of:
storage and ZFS operations, cluster and quorum work, datastores and jobs,
backup and restore, firewall, SDN, migrations, remotes, permissions, and
anything whose flags you would otherwise be guessing at.

### When to go to the internet

The local PVE and PBS docs describe how the software works, but they say
nothing about what changed in a release or which bugs are known. Fetch those
from the web when:

- `docs.py status` reports the online notes are **MISSING** (that is how a
  version change announces itself - the host moved to a release whose notes have
  never been fetched),
- a major upgrade is being planned (the upgrade guides live only on the wiki),
- an error is not explained by the local docs and may be a known regression.

PDM is the exception: its release notes and known issues are in the local
docs (`roadmap.html`).

| What | Where |
|---|---|
| PVE release notes and known issues | `https://pve.proxmox.com/wiki/Roadmap` (anchors `#Proxmox_VE_<major>.<minor>`, `#<major>.<minor>-known-issues`) |
| PBS release notes and known issues | `https://pbs.proxmox.com/wiki/Roadmap` (anchors `#Proxmox_Backup_Server_<major>.<minor>`, `#<major>.<minor>-known-issues`) |
| Major upgrade guides | `https://pve.proxmox.com/wiki/Upgrade_from_<old>_to_<new>`, `https://pbs.proxmox.com/wiki/Upgrade_from_<old>_to_<new>` |
| Docs of a *newer* release than installed | `https://pve.proxmox.com/pve-docs/`, `https://pbs.proxmox.com/docs/`, `https://pdm.proxmox.com/docs/` |
| Bug reports | `https://bugzilla.proxmox.com` |
| Real-world reports of an error | `https://forum.proxmox.com` - useful for symptoms, but treat forum posts as leads to verify, not as instructions to follow |

After fetching, write a short summary (what changed, what breaks, what to watch)
to the path from `docs.py --product <pve|pbs> online-path`. It is then cached
for this version, so the next session starts informed instead of refetching.

## 4. Changing anything requires a go-ahead

Read-only investigation needs no permission - run whatever helps you understand
the system. Anything that writes, installs, starts, stops or reboots gets
proposed first, in this shape (labels in the user's language too):

```
Proposal: <one line - what and why>
Affects:  <which guests/services, expected downtime, what the user will notice>
Commands: <the exact commands, in order>
Rollback: <how to undo it - snapshot, config backup, previous package version>
Risk:     <what could still go wrong, and how you would notice>
```

Then wait. After a go-ahead, run the commands, show the real output, and say
plainly whether it worked - including when it did not.

Guidance that keeps changes reversible on every product:

- **Use the product's tooling, not a text editor.** `qm`, `pct`, `pvesm`,
  `pveum`, `pvecm` on PVE, `proxmox-backup-manager` on PBS and the PDM
  admin/client CLIs validate input and keep state consistent. Where no CLI
  exists, copy the file to `/root/` first, then edit.
- **Never `apt upgrade` on Proxmox - always `apt full-upgrade`** (the same as
  `dist-upgrade`). Plain `upgrade` never removes a package, so updates that
  replace or drop one are held back and the stack ends up half-updated.
- **Network changes can lock you out.** Changes staged in the GUI land in
  `/etc/network/interfaces.new` and only apply on reboot or via Apply. Make sure
  there is a way back in (other node, IPMI, console) before applying.
- **Keep a known-good kernel installed** when clearing space; do not remove the
  one currently running or the last one that booted successfully.

On PVE specifically:

- `/etc/pve` is a FUSE mount backed by a replicated database, not an ordinary
  directory; hand-editing it can desync nodes or be silently reverted. **Check
  quorum before touching it** - without quorum it is read-only and writes fail
  in confusing, half-applied ways.
- **Snapshot or back up before destructive guest work.** If the storage supports
  snapshots (ZFS does), `qm snapshot` / `pct snapshot` costs seconds and buys a
  clean rollback. Verify a recent backup exists before deleting or restoring.

If the user tells you to go ahead with something you flagged as risky, say your
concern once, then do what they asked - it is their server.

## 5. PVE cluster awareness

Determine the cluster shape from `check.sh --section cluster` rather than
assuming. Two facts change how you plan almost every job:

- **A cluster of two nodes without a QDevice cannot survive one node leaving.**
  Expected votes is 2, so rebooting one drops the survivor below quorum and its
  `/etc/pve` turns read-only until the other returns. Upgrade and reboot one node
  at a time, and bring each fully back before starting the next. A QDevice on a
  third always-on machine removes this limitation.
- **Node directories under `/etc/pve/nodes/` can outlive their node.** A leftover
  directory (including a case-mismatched duplicate) keeps stale guest configs
  visible and confuses migrations. Check membership against `corosync.conf`
  before concluding a node is real.

For migrations, HA, and node removal, read
`${CLAUDE_SKILL_DIR}/references/pve/changes.md`; removing a node in particular is
one of the few genuinely unrecoverable operations in PVE.

## 6. Deeper references

Load the files of the product you are working on, when the task calls for
them - they are detail, not preamble. Each product has the same three:

- `diagnose.md` - symptom-to-cause routes. Start here when something is broken.
- `changes.md` - recipes for common changes done the reversible way, plus the
  operations that deserve extra care.
- `upgrades.md` - routine updates, reboots and major version upgrades.

| Product | Directory |
|---|---|
| PVE | `${CLAUDE_SKILL_DIR}/references/pve/` |
| PBS | `${CLAUDE_SKILL_DIR}/references/pbs/` |
| PDM | `${CLAUDE_SKILL_DIR}/references/pdm/` (built from the docs, not yet verified on a real PDM host) |

## Working style

Prefer the smallest action that answers the question. A user asking why one
container will not start wants that container looked at, not a full audit - but
if the sweep you already ran surfaced a failing disk or an expired certificate,
say so briefly at the end, because a host's problems rarely stay local.

State findings with the evidence attached: the command, the line from its output,
and the doc section that explains it. On a machine that other people's services
depend on, "I checked X and it says Y" is worth far more than a confident
assertion the user cannot verify.
