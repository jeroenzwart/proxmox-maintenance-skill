# Design: cover PVE, PBS and PDM in one skill

Date: 2026-11-17
Status: draft, awaiting approval

## Intent

The `proxmox-maintenance` skill only knows Proxmox VE. The owner also runs
Proxmox Backup Server (PBS) and Proxmox Datacenter Manager (PDM) and wants the
same working method - look first, read the docs for this exact version,
propose, act only with a go-ahead - on those hosts too. The content should be
split per product instead of one PVE-shaped manual.

## Goals

- One skill, installed with one `git clone` per host, that recognises which of
  PVE, PBS and PDM is installed on the host it runs on and works with the
  matching checks and references.
- A read-only health check per product, with the same output conventions as
  today (sections, `!!` for problems, a summary line).
- One docs indexer that searches the locally installed, version-matched
  manual of each installed product.
- References split per product: diagnose, changes, upgrades.

## Non-goals

- Proxmox Mail Gateway, Ceph-specific depth, PBS tape beyond a short listing.
- Using the backup client inside guests (that is guest work, as today).
- Managing hosts remotely. The skill works on the host it runs on; the
  existing PVE `--cluster` SSH sweep stays as it is.
- A plugin/marketplace (dropped earlier).

## Anti-goals

- Any check that writes, starts, stops or changes state. Checks stay
  read-only; the only writes are the docs cache, as today.
- Answering from memory where the installed docs answer it.
- A check that hangs on an unreachable PDM remote: every network call has a
  timeout.

## Constraints

- Runs as root on a Debian 13 (Trixie) based host: PVE 9.2, PBS 4.2, PDM 1.1
  are current. PBS 3 is end of life since 2026-08 and must be flagged.
- No dependencies beyond what the product ISOs ship. `python3` is assumed
  present on all three (verify on a PBS and a PDM host before building).
- `SKILL.md` description stays at or under 1024 characters; body under 500
  lines. All content in English.
- Install path stays `~/.claude/skills/proxmox-maintenance` (skill name
  unchanged).

## Approaches

1. **One skill, split per product inside** - chosen by the owner. Shared
   method in `SKILL.md`, product detection, per-product checks and references,
   one docs indexer. One install per host; the description has to cover three
   products, so triggering is a little less sharp.
2. Three separate skills in one repo - sharper descriptions and less context
   per load, but the method is duplicated three times and install needs a
   symlink per skill.
3. A core skill plus product skills that reference it - least duplication,
   but cross-skill references are fragile and it is the most moving parts.

## Design

### Layout

```
SKILL.md                     shared method, product detection, per-product must-knows
scripts/
  check.sh                   entrypoint: detect products, run common + product sections
  checks/common.sh           helpers (sec/warn/note/have) and host-level sections
  checks/pve.sh              PVE sections (today's pve-check.sh content)
  checks/pbs.sh              PBS sections
  checks/pdm.sh              PDM sections
  docs.py                    docs indexer for all products (was pve-docs.py)
references/
  pve/diagnose.md  pve/changes.md  pve/upgrades.md   (today's files, moved)
  pbs/diagnose.md  pbs/changes.md  pbs/upgrades.md
  pdm/diagnose.md  pdm/changes.md  pdm/upgrades.md
tests/
  fixtures/                  sample HTML and command output
  test_docs.py               parser tests (asciidoc and Sphinx)
```

### Product detection

A product counts as installed when its server package is in state
`install ok installed` (`dpkg-query -W -f '${Status}'`):

| Product | Package | Main units |
|---|---|---|
| PVE | `pve-manager` | `pve-cluster`, `pveproxy`, `pvedaemon` |
| PBS | `proxmox-backup-server` | `proxmox-backup`, `proxmox-backup-proxy` |
| PDM | `proxmox-datacenter-manager` | `proxmox-datacenter-api`, `proxmox-datacenter-privileged-api` |

`proxmox-backup-client` is not a PBS signal: every PVE host has it. More than
one product can be present (PBS co-installed on PVE is documented, though
not recommended); then all detected products are checked in one run.

### `check.sh`

- `check.sh [--full] [--cluster] [--product pve|pbs|pdm] [--section NAME]`
- The first output block lists the detected products and their versions.
- Host-level sections in `common.sh`, run once per host: identity (host,
  Debian release, kernel, reboot pending), services (failed units plus the
  product's units), packages (pending updates, broken packages, repository
  suites and leftovers - today's logic), certs, network, zfs, disk, smart,
  logs.
  - `zfs` and `disk` are today's ZFS and root-filesystem checks, moved out of
    the PVE `storage` section: a PBS datastore on a degraded pool is the most
    important finding on a backup server. PVE `storage` keeps `pvesm` and the
    node-restricted storages. *(Builder's-check call.)*
  - Where today's host-level logic is PVE-specific it switches on the
    detected product: `pveversion`/`pvesubscription` only on PVE; the
    highlighted pending updates per product (`pve-manager`, `proxmox-backup`,
    `proxmox-datacenter-manager`, kernel, zfs); certs adds each product's own
    certificate files (PBS and PDM paths to be confirmed on a host);
    `interfaces.new` only on PVE. PDM has no separate `cert` section.
    *(Builder's-check call.)*
  - In a container (`systemd-detect-virt --container`), `smart`, `zfs`,
    kernel/reboot and `network` conflicts are skipped with a note: the
    container has no disks or kernel of its own. *(Builder's-check call.)*
- Product sections:
  - PVE: cluster, storage, guests, backup - today's logic unchanged, including
    the fixes already committed.
  - PBS: `datastores` (config, usage above 85%, maintenance mode, removable
    store not mounted), `gc` (last run failed, never run, not scheduled),
    `jobs` (last state of sync/verify/prune jobs via
    `proxmox-backup-debug api get /admin/{sync,verify,prune,gc}`), `tasks`
    (failed tasks in `task list --all --limit 50`), `remotes`, `tape` (only if
    configured), plus a warning when PBS is 3.x (end of life).
  - PDM: `remotes` (list, reachability via `remote version <id>` with a
    timeout, fingerprint/certificate errors), `subscriptions` (the 80% rule
    for enterprise repo access), `cert` (own certificate expiry), the daily
    update timer.
- `--section` accepts the union of all section names and is validated as
  today; a section of a product that is not installed is an error.
- JSON output (`--output-format json`) is parsed with small inline `python3`
  snippets; no `jq` dependency.

### `docs.py`

- Same commands as today (`status`, `sync`, `search`, `show`, `online-path`)
  plus `--product`. With one product installed it is implied; with several,
  `search` covers all and prefixes ids with the product (`pbs:maintenance#...`).
- Product table: docs dir, version package, docs package, release-notes URL
  pattern.
  - PVE: `/usr/share/pve-docs`, `pve-manager`, `pve-docs`,
    `pve.proxmox.com/wiki/Roadmap#Proxmox_VE_<X.Y>` / `#<X.Y>-known-issues`.
  - PBS: `/usr/share/doc/proxmox-backup/html`, `proxmox-backup-server`,
    `proxmox-backup-docs`, `pbs.proxmox.com/wiki/Roadmap#Proxmox_Backup_Server_<X.Y>`
    / `#<X.Y>-known-issues`.
  - PDM: `/usr/share/doc/proxmox-datacenter-manager/html`,
    `proxmox-datacenter-manager`, `proxmox-datacenter-manager-docs`; release
    notes are local (`roadmap.html`), so no online notes are needed.
- Version from `dpkg-query` for every product (replaces `pveversion`).
- Sphinx support (PBS and PDM): strip the `¶` headerlink from titles, ignore
  `div.sphinxsidebar`, skip `genindex.html`, `search.html`, `index.html`.
  Anchors come from `<section id>`, which the existing pending-id logic
  already picks up.
- Cache per product: `~/.cache/proxmox-skill/<product>/`. The old flat index
  is simply rebuilt; leftover files are harmless.

### `SKILL.md`

- Description rewritten to name PVE, PBS and PDM and their typical symptoms,
  within 1024 characters.
- Body: the shared method (orient, docs, propose-then-act, working style),
  how to read the detected-products block, and a compact "must know" list per
  product (the four current PVE findings; for PBS: prune frees nothing until
  GC runs, GC needs atime/relatime, fingerprint changes break PVE storage and
  sync remotes; for PDM: pinned fingerprints, unreachable remotes, the 80%
  subscription rule). Detail lives in the references.
- `allowed-tools` updated to the new script names (read-only commands only).

### Older releases

PBS 3.x and PVE 8.x (Debian 12) are detected and flagged (PBS 3 as end of
life), and the upgrade references guide the jump. The checks are best effort
there: a command or endpoint that is missing prints a note instead of a
warning or an error; no separate code paths per old release.
*(Builder's-check call.)*

### References for PBS and PDM

Written from the installed docs and the research notes in
`2026-11-17-pbs-pdm-research.md`; same tone and shape
as the PVE files (commands first, causes ranked by how often they are the
real one, doc section ids to cite). Upgrades cover PBS 3 to 4 (`pbs3to4
--full`, read-only maintenance mode on datastores during the upgrade) and PDM
minor updates.

### Tests

The builder has no access to the owner's hosts. Before the PBS and PDM
commits, the builder hands the owner a block of read-only commands (versions,
`python3 --version`, docs folder listings, every command the checks will
parse, in JSON where available). The owner runs it on the host and returns
the output. That output is the ground truth for the parsing code and, with
hostnames, IPs, fingerprints and datastore names replaced, becomes the test
fixtures. The finished check scripts are run once more by the owner on the
host before merging.

`tests/test_docs.py` (stdlib `unittest`, no dependencies) parses a trimmed
asciidoc page and a trimmed Sphinx page from `tests/fixtures/` and checks
titles, anchors, the stripped `¶` and the ignored sidebar. Check scripts are
verified by running them on real hosts; their parsing of JSON is covered by
fixture output where it is non-trivial (PBS job states).

### Commits

1. `refactor`: move PVE into the per-product layout and rename the scripts
   (no behaviour change).
2. `feat`: product-agnostic `docs.py` with Sphinx support and tests.
3. `feat`: PBS checks and references.
4. `feat`: PDM checks and references.
5. `docs`: `SKILL.md` and README for three products. The README's benchmark
   figures are marked as measured on PVE only; re-running the evals (whose
   prompts live outside the repo) is not part of this work.
   *(Builder's-check call.)*

Commit 1 moves the ZFS and disk checks into host-level sections, so PVE
output changes in where those warnings appear, not in what they say.

## Left to the builder

- Exact section names and warning wording, within the conventions above.
- How `common.sh` is sourced (relative to the script's own directory).
- The PBS `!!` thresholds beyond those named here.
