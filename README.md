<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo/lockup-horizontal-reversed.svg">
    <img src="assets/logo/lockup-horizontal-color.svg" alt="Proxmox Maintenance" width="480">
  </picture>
</p>

A Claude Code skill for maintaining Proxmox VE hosts and clusters: health
checks, diagnosing failures, making changes safely, and planning updates and
version upgrades.

Its guiding idea is that a hypervisor is not an ordinary Linux box. A careless
command does not break a program, it breaks every service running on the
machine, and `/etc/pve` adds failure modes with no equivalent elsewhere. So the
working order is: **look first, read the manual for this exact version, propose,
then act only with a go-ahead.**

## Installing

```bash
git clone https://github.com/jeroenzwart/proxmox-maintenance-skill.git \
  ~/.claude/skills/proxmox-maintenance
```

Update with `git -C ~/.claude/skills/proxmox-maintenance pull`, then start a new
Claude Code session.

Run it on the Proxmox host itself (or wherever your Claude Code session has
access to it). No dependencies beyond what a PVE host already ships: Python 3,
bash, and the `pve-docs` package.

## What is inside

| Path | Purpose |
|---|---|
| `SKILL.md` | The working method, and the four findings worth carrying into any answer |
| `scripts/check.sh` | Read-only health snapshot: cluster/quorum, ZFS per vdev, SMART with temperature and wear, backup coverage, repositories, certificates, network conflicts. Cluster-wide over SSH with `--cluster` |
| `scripts/pve-docs.py` | Search the admin guide for the *running* version, from the copy installed on the host |
| `references/pve/diagnose.md` | Symptom-to-cause routes per subsystem |
| `references/pve/changes.md` | Reversible recipes for common changes, and the operations that deserve care |
| `references/pve/upgrades.md` | Repositories, kernels, reboots around quorum, major upgrades |

## Two design decisions worth knowing

**The documentation is already local.** The `pve-docs` package installs the
complete admin guide under `/usr/share/pve-docs/`, and apt keeps it in step with
the installed PVE version. Downloading a manual is therefore unnecessary and
risks answering from the wrong release. `pve-docs.py` indexes that HTML into
searchable text and rebuilds the index automatically the moment `pveversion` or
the docs package changes. Only what is genuinely not local - release notes,
known issues, upgrade guides - is fetched from the web and cached per version.

**Everything observed is observed read-only.** `check.sh` starts, stops,
installs and writes nothing, so it is always safe as a first step. Changes are
proposed in a fixed shape - what, what it touches, the commands, the way back,
the remaining risk - and executed only after the user agrees.

## How well does it work

Benchmarked against the same prompts run without the skill, six test cases over
three iterations on a live two-node cluster:

| | Iteration 1 | Iteration 2 | Iteration 3 |
|---|---|---|---|
| With skill | 88.9% | 100% | 100% |
| Without skill | 84.1% | 90.5% | 85.7% |

Triggering accuracy on 20 realistic queries: 19/20, with the one miss fixed
afterwards. The baseline is strong on its own - the skill's value is that what
the model *can* find, it *does* find, every time, with the documentation section
cited so the claim can be checked.

The test prompts behind those numbers are kept out of this repository: they were
written against a specific cluster and name its nodes, pools and guests.
