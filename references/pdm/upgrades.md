# Updating Proxmox Datacenter Manager

Built from the PDM 1.1 documentation; not yet verified on a real PDM host.

## Release notes are local

Unlike PVE and PBS, PDM ships its roadmap - release notes and known issues
included - in the installed docs (`roadmap.html`). Read them there; they match
the installed version:

```bash
python3 <skill-dir>/scripts/docs.py --product pdm search roadmap known issues
```

Anchors follow `roadmap.html#proxmox-datacenter-manager-<X>-<Y>` and
`#known-issues-breaking-changes-<X>-<Y>`.

## Routine updates

Minor updates (for example 1.0 to 1.1) are ordinary package updates:

```bash
apt update
apt list --upgradable
apt full-upgrade
proxmox-datacenter-manager-admin versions
```

Before updating, note the breaking changes for the target version: scripts
and integrations that call the PDM API are the usual casualties.

## Major upgrades

`pdmAtoB` is the checker for the jump from the 0.x releases (Debian 12) to 1.x
(Debian 13). Follow the upgrade guide on the Proxmox wiki for that jump and
resolve every warning the checker reports before changing repositories. For
later majors, the release notes name the checker and the guide.
