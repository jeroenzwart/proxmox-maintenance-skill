<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo/lockup-horizontal-reversed.svg">
    <img src="assets/logo/lockup-horizontal-color.svg" alt="Proxmox Maintenance" width="480">
  </picture>
</p>

A Claude Code skill for maintaining Proxmox hosts - Proxmox VE (PVE), Proxmox
Backup Server (PBS) and Proxmox Datacenter Manager (PDM): health checks,
diagnosing failures, making changes safely, and planning updates and version
upgrades.

Its guiding idea is that a Proxmox host is not an ordinary Linux box. A careless
command does not break a program: on a hypervisor it breaks every service
running on the machine, on a backup server it can cost the only copy of
something. So the working order is: **look first, read the manual for this exact version, propose,
then act only with a go-ahead.**

## Installing

```bash
git clone https://github.com/jeroenzwart/proxmox-maintenance-skill.git \
  ~/.claude/skills/proxmox-maintenance
```

Update with `git -C ~/.claude/skills/proxmox-maintenance pull`, then start a new
Claude Code session.

Run it on the Proxmox host itself; install it on every host you want it to
look after. It detects which products are installed. No dependencies beyond
what the Proxmox ISOs already ship: Python 3, bash and the docs package of
each product.

## What is inside

| Path | Purpose |
|---|---|
| `SKILL.md` | The working method, and per product the findings worth carrying into any answer |
| `scripts/check.sh` | Read-only health snapshot. Detects PVE, PBS and PDM, then runs host-level sections (packages, repositories, certificates, network conflicts, ZFS per vdev, SMART with temperature and wear) and the sections of each product. PVE cluster-wide over SSH with `--cluster` |
| `scripts/checks/` | The sections: `common.sh` (host-level), `pve.sh`, `pbs.sh`, `pdm.sh` |
| `scripts/docs.py` | Search the manual of each installed product for the *running* version, from the copy installed on the host |
| `references/<product>/` | Per product: `diagnose.md` (symptom to cause), `changes.md` (reversible recipes), `upgrades.md` (updates and major upgrades) |
| `tests/` | `python3 -m unittest discover -s tests` |

PDM support is built from the PDM 1.1 documentation and has not yet been
verified on a real PDM host.

## Two design decisions worth knowing

**The documentation is already local.** Each product installs its complete
manual as HTML (`pve-docs`, `proxmox-backup-docs`,
`proxmox-datacenter-manager-docs`), and apt keeps it in step with the installed
version. Downloading a manual is therefore unnecessary and risks answering from
the wrong release. `docs.py` indexes that HTML into searchable text and rebuilds
the index automatically the moment the product or its docs package changes.
Only what is genuinely not local - PVE and PBS release notes, known issues,
upgrade guides - is fetched from the web and cached per version.

**Everything observed is observed read-only.** `check.sh` starts, stops,
installs and writes nothing, so it is always safe as a first step. Changes are
proposed in a fixed shape - what, what it touches, the commands, the way back,
the remaining risk - and executed only after the user agrees.

## How well does it work

Benchmarked against the same prompts run without the skill, six test cases over
three iterations on a live two-node PVE cluster. These figures predate PBS and
PDM support and cover PVE only:

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
