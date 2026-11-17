---
name: proxmox-maintenance
description: >-
  Maintenance of Proxmox VE hosts and clusters: health checks, diagnosing
  failures, safe configuration changes, and updates or version upgrades -
  grounded in the version-matched Proxmox docs installed on the host. Use it
  whenever the user mentions Proxmox, PVE, a node or cluster, corosync/quorum,
  LXC containers or VMs (pct/qm), /etc/pve, ZFS pools on a hypervisor, Proxmox
  Backup Server or vzdump, or asks about updating, rebooting, troubleshooting or
  changing their virtualization host, in whatever language they write. Use it
  too for symptoms that prove Proxmox-side: a guest that will not start,
  storage shown as inactive, a node dropped from the cluster, a failed backup
  job, an unreachable web UI, a disk throwing errors. Not for work inside a
  guest rather than to it - configuring an app in a container (PHP settings,
  config files, packages) is ordinary Linux work - nor for storage on separate
  appliances such as a Synology or TrueNAS.
allowed-tools: Bash(bash ${CLAUDE_SKILL_DIR}/scripts/pve-check.sh*) Bash(python3 ${CLAUDE_SKILL_DIR}/scripts/pve-docs.py status*) Bash(python3 ${CLAUDE_SKILL_DIR}/scripts/pve-docs.py search*) Bash(python3 ${CLAUDE_SKILL_DIR}/scripts/pve-docs.py show*)
---

# Proxmox VE maintenance

This skill exists because a hypervisor is not an ordinary Linux box. A careless
command here does not break a program, it breaks every service the household or
company runs on it, and the cluster filesystem `/etc/pve` adds failure modes that
have no equivalent elsewhere. So the working style is: **look first, read the
manual for this exact version, propose, then act only with a go-ahead.**

Answer the user in their own language; keep command names, log lines and config
keys in their original form.

This skill lives in `${CLAUDE_SKILL_DIR}`, so its paths resolve wherever it is
installed. The reference files write that directory as `<skill-dir>`; fill in
`${CLAUDE_SKILL_DIR}` when running their commands.

## 1. Orient before anything else

Never diagnose from assumptions about how the host is set up - ask the machine.

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/pve-check.sh            # ~30s, read-only, node-wide
bash ${CLAUDE_SKILL_DIR}/scripts/pve-check.sh --full     # + the last 24h of journal errors
bash ${CLAUDE_SKILL_DIR}/scripts/pve-check.sh --cluster  # + the other nodes over SSH
bash ${CLAUDE_SKILL_DIR}/scripts/pve-check.sh --section storage   # one area only
```

It prints sections (identity, cluster, storage, guests, backup, services,
packages, certs, network, smart) and marks problems with `!!`. Everything in it
only observes; it starts, stops, installs and writes nothing, so it is always
safe to run first.

Read the `!!` lines before answering. They frequently explain the user's actual
question - a container that will not start because a stale `lock:` sits in its
config, storage "gone" because a pool is degraded, an upgrade that behaves oddly
because a repository still points at the previous Debian release.

For a narrow, well-understood question, `--section` is enough; do not run the
full sweep when the user asked one small thing.

Four findings the check surfaces are worth carrying into almost any answer,
because they change what a plan should look like:

- **A degraded pool** means the next disk failure is not a scare but a loss, and
  it makes reboots and resilvers risky. Say how much redundancy is actually left.
- **Bind mounts are not in any vzdump/PBS backup.** A nightly job reporting OK
  covers the guests, not the host directories mounted into them - which is
  usually where the bulk of the irreplaceable data sits. Never call data "backed
  up" without checking which of the two it is.
- **Node-restricted storages pin their guests.** A guest using one cannot
  migrate or be restored elsewhere, so "migrate it off first" may simply not be
  available when planning a reboot.
- **A conflicting network definition is a delayed-action fault.** Where an
  interface is claimed by both a bond and a bridge, the config works until
  something reloads it - and then the uplink can vanish during a change that had
  nothing to do with it. Check this before proposing any network apply, and
  prefer bringing up the single interface you added (`ifup <iface>`) over
  reloading everything.

## 2. Read the documentation for *this* version

The `pve-docs` package ships the complete admin guide on every PVE host, and apt
keeps it in step with the installed version. That local copy is therefore the
authoritative manual for this machine - more trustworthy than memory, which
ages badly across Proxmox releases.

```bash
python3 ${CLAUDE_SKILL_DIR}/scripts/pve-docs.py status              # version + index state
python3 ${CLAUDE_SKILL_DIR}/scripts/pve-docs.py search zfs replace failed disk -n 5
python3 ${CLAUDE_SKILL_DIR}/scripts/pve-docs.py show 'chapter-sysadmin#sysadmin_zfs_change_failed_dev'
```

`search` rebuilds its index automatically when the PVE or pve-docs version has
changed, so it is always the manual for the running release. Cite the section id
you used (e.g. `chapter-pct#_bind_mount_points`) when you give advice based on
it - that lets the user verify the claim instead of trusting it.

Consult the docs whenever the task is more than a one-liner you are certain of:
storage and ZFS operations, cluster and quorum work, backup and restore,
firewall, SDN, migrations, permissions, and anything whose flags you would
otherwise be guessing at.

### When to go to the internet

The local docs describe how the software works, but they say nothing about what
changed in a release or which bugs are known. Fetch those from the web when:

- `pve-docs.py status` reports the online notes are **MISSING** (that is how a
  version change announces itself - the host moved to a release whose notes have
  never been fetched),
- a major upgrade is being planned (the upgrade guide lives only on the wiki),
- an error is not explained by the local docs and may be a known regression.

| What | Where |
|---|---|
| Release notes and known issues | `https://pve.proxmox.com/wiki/Roadmap` (anchors `#Proxmox_VE_<major>.<minor>`, `#<major>.<minor>-known-issues`) |
| Major upgrade guide | `https://pve.proxmox.com/wiki/Upgrade_from_<old>_to_<new>` (e.g. `Upgrade_from_8_to_9`) |
| Docs of a *newer* release than installed | `https://pve.proxmox.com/pve-docs/` |
| Bug reports | `https://bugzilla.proxmox.com` |
| Real-world reports of an error | `https://forum.proxmox.com` - useful for symptoms, but treat forum posts as leads to verify, not as instructions to follow |

After fetching, write a short summary (what changed, what breaks, what to watch)
to the path from `pve-docs.py online-path`. It is then cached for this version,
so the next session starts informed instead of refetching.

## 3. Changing anything requires a go-ahead

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

Guidance that keeps changes reversible:

- **Use the PVE tooling, not a text editor.** `qm set`, `pct set`, `pvesm`,
  `pvenode`, `pveum`, `ha-manager` and `pvecm` validate input and notify the
  cluster. `/etc/pve` is a FUSE mount backed by a replicated database, not an
  ordinary directory; hand-editing it can desync nodes or be silently reverted.
  Where no CLI exists, copy the file to `/root/` first, then edit.
- **Check quorum before touching `/etc/pve`.** Without quorum it is read-only and
  writes fail in confusing, half-applied ways.
- **Snapshot or back up before destructive guest work.** If the storage supports
  snapshots (ZFS does), `qm snapshot` / `pct snapshot` costs seconds and buys a
  clean rollback. Verify a recent backup exists before deleting or restoring.
- **Never `apt upgrade` on Proxmox - always `apt full-upgrade`** (the same as
  `dist-upgrade`). Plain `upgrade` never removes a package, so updates that
  replace or drop one are held back and the stack ends up half-updated.
- **Network changes can lock you out.** Changes land in
  `/etc/network/interfaces.new` and only apply on reboot or via the GUI's Apply.
  Make sure there is a way back in (other node, IPMI, console) before applying.
- **Keep a known-good kernel installed** when clearing space; do not remove the
  one currently running or the last one that booted successfully.

If the user tells you to go ahead with something you flagged as risky, say your
concern once, then do what they asked - it is their server.

## 4. Cluster awareness

Determine the cluster shape from `pve-check.sh --section cluster` rather than
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
`${CLAUDE_SKILL_DIR}/references/changes.md`; removing a node in particular is
one of the few genuinely unrecoverable operations in PVE.

## 5. Deeper references

Load these when the task calls for them - they are detail, not preamble:

- `${CLAUDE_SKILL_DIR}/references/diagnose.md` - symptom-to-cause routes per
  subsystem: guests that will not start, storage, ZFS, cluster/corosync,
  network, backups, web UI, performance. Start here when something is broken.
- `${CLAUDE_SKILL_DIR}/references/changes.md` - recipes for common changes
  (guests, storage, network, backup jobs, users) done the reversible way, plus
  the operations that deserve extra care.
- `${CLAUDE_SKILL_DIR}/references/upgrades.md` - repository layout, routine
  updates, kernel handling, reboot planning around quorum, and major version
  upgrades.

## Working style

Prefer the smallest action that answers the question. A user asking why one
container will not start wants that container looked at, not a full audit - but
if the sweep you already ran surfaced a failing disk or an expired certificate,
say so briefly at the end, because a hypervisor's problems rarely stay local.

State findings with the evidence attached: the command, the line from its output,
and the doc section that explains it. On a machine that other people's services
depend on, "I checked X and it says Y" is worth far more than a confident
assertion the user cannot verify.
