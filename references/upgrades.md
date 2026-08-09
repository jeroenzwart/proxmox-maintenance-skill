# Updates, kernels and version upgrades

## How the repositories fit together

A PVE host draws from three families of repository: Debian's own (base OS and
security), Proxmox's PVE repository, and optionally a Ceph repository. Each has
an enterprise variant (needs a subscription) and a no-subscription variant.

```bash
ls /etc/apt/sources.list.d/
cat /etc/apt/sources.list
apt policy                       # what is actually being used, and at what priority
```

Two things to check whenever updates behave strangely:

- **Suite names must match the Debian release.** After a major upgrade the old
  repository files often survive - a `bookworm` entry on a `trixie` host will
  either 404 or, worse, offer packages from the previous generation. The health
  check flags these; they should be removed, not commented out one line at a
  time.
- **The enterprise repository without a subscription** makes `apt update` fail
  with `401 Unauthorized`. Either disable it or switch to no-subscription;
  leaving it enabled and broken hides real update errors in the noise.
- **`.dpkg-dist` / `.dpkg-old` leftovers** mean a packaged change to a repo file
  was never merged. Compare and merge them; apt ignores them, so what you see in
  the file may not be what Proxmox intended to ship.

Newer PVE versions use the deb822 `.sources` format. A repository can be defined
twice - once in the old `.list` format and once in `.sources` - which is a common
source of duplicate-entry warnings.

## Routine updates

```bash
apt update
apt list --upgradable
apt dist-upgrade                 # NOT `apt upgrade`
```

`apt upgrade` refuses to install packages that need new dependencies or removals,
which is exactly the shape of most PVE updates - it silently leaves the stack
half-updated. `dist-upgrade` (or `pveupgrade`, a thin wrapper that adds warnings
about reboots) is the supported path.

Before upgrading a node that runs guests:

1. Confirm recent backups exist and succeeded.
2. Check what is being upgraded: kernel, `pve-manager`, `pve-qemu-kvm`, `zfs`,
   `corosync` and `ceph` are the packages that carry real consequences.
3. On a cluster, upgrade one node at a time.

`pve-qemu-kvm` updates apply to a VM only after it is fully stopped and started
again (a reboot from inside the guest is not enough), and `zfs` module updates
apply on host reboot. So a "completed" upgrade can still be partially in effect.

## Kernels and reboots

```bash
uname -r                                        # what is running
dpkg -l 'proxmox-kernel-*' | awk '/^ii/{print $2, $3}'
proxmox-boot-tool kernel list                   # what may boot (systemd-boot/ZFS root)
proxmox-boot-tool kernel pin <version>          # stay on a known-good kernel
proxmox-boot-tool kernel unpin
```

A newer installed kernel than the running one means a reboot is pending - the
health check reports this. Keep at least one known-good older kernel installed;
if a new kernel misbehaves (common with NIC and HBA drivers, and with passthrough
setups), pinning the previous one restores service without downgrading anything
else.

Old kernels do accumulate and can fill `/boot`. Remove them deliberately, never
the running one or the last known-good one.

**A pinned kernel and `apt autoremove` are a dangerous pair.** Once an upgrade
moves the kernel meta-package forward, the pinned older kernel can stop being
anyone's dependency and gets classed as automatically installed and no longer
needed. An `autoremove` then deletes the very kernel the bootloader is pinned
to, and the node does not come back from its next reboot. After upgrading a host
with a pin, either lift the pin deliberately or mark the pinned kernel manual
(`apt-mark manual proxmox-kernel-<version>-pve-signed`) - and check the removal
list of any `autoremove` before confirming it.

A pin also silences part of an upgrade quietly: the ZFS kernel module ships
inside the kernel package, so a pinned kernel keeps the old module while the
userland tools move on. Within one minor ZFS release that is harmless, but it
means the reboot did not deliver what the user thought it did. Say so.

## Rebooting a node in a cluster

With HA configured, guests migrate automatically; without it, plan the move.

```bash
qm migrate <id> <targetnode> --online          # live migration for VMs
pct migrate <id> <targetnode> --restart        # containers need a restart
ha-manager status
```

On a **two-node cluster without a QDevice**, expect quorum loss for the duration:
the remaining node drops to one vote out of two expected and its `/etc/pve`
becomes read-only until the rebooted node returns. Guests keep running, but no
configuration change is possible in the meantime. So: reboot one node, wait for
it to rejoin and for `pvecm status` to show quorum restored, and only then touch
the other. A QDevice on any small always-on machine (it needs no Proxmox) removes
this constraint permanently.

After a reboot, verify rather than assume:

```bash
pvecm status                     # quorum restored, both nodes present
qm list ; pct list               # guests back up
zpool status -x
systemctl --failed
```

## Major version upgrades

A major upgrade (8 → 9, and later 9 → 10) also moves the Debian base to a new
release. Never improvise this one - Proxmox publishes a checker and a guide, and
the guide is the authority:

```bash
pve8to9 --full        # the checker for 8.4 -> 9; later majors ship an equivalent
```

The sequence, in order:

1. Update fully within the current major first, and reboot into the newest
   kernel. The checker assumes a fully patched starting point.
2. Run the checker and resolve every failure and warning it reports. Its warnings
   are the accumulated experience of the upgrades that went wrong.
3. Read the wiki upgrade guide for that specific jump
   (`https://pve.proxmox.com/wiki/Upgrade_from_8_to_9`) and the release notes and
   known issues on the Roadmap page. Fetch these from the web - they are not in
   the locally installed docs.
4. Verify backups of every guest, and of `/etc/pve` itself.
5. Update the repository entries to the new Debian suite, then `apt update` and
   `apt dist-upgrade`.
6. On a cluster: one node at a time, verifying the cluster is healthy between
   nodes. Mixed versions are supported during the upgrade window, not as a
   permanent state.
7. Reboot, then check quorum, guests, storage and the web UI before moving on.

After any version change, run `pve-docs.py status`. It will report that the
online notes for the new version are missing - fetch the release notes and known
issues and cache them, so later sessions know what changed on this host.

## When an update breaks something

```bash
grep -E 'upgrade|install' /var/log/dpkg.log | tail -40    # what changed, exactly
apt-cache policy <package>                                # versions available
apt install <package>=<previous-version>                  # deliberate downgrade
```

`/var/log/dpkg.log` and `/var/log/apt/history.log` give the precise before/after
of the change, which is usually faster than reasoning about what "the update"
did. For a kernel, pin the previous one instead of downgrading packages. Check
the Roadmap known-issues section and the forum before concluding the problem is
local to this host - regressions are usually noticed by many people within days.
