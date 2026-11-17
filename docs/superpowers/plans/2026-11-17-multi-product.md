# Multi-product (PVE, PBS, PDM) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the `proxmox-maintenance` skill from PVE-only to PVE, PBS and PDM, split per product.

**Architecture:** `scripts/check.sh` detects the installed products and runs host-level sections from `scripts/checks/common.sh` plus product sections from `scripts/checks/{pve,pbs,pdm}.sh`. `scripts/docs.py` indexes the local manual of every installed product. References move to `references/{pve,pbs,pdm}/`.

**Tech Stack:** bash, python3 stdlib (`unittest` for tests), GNU coreutils on the hosts.

**Spec:** `docs/superpowers/specs/2026-11-17-multi-product-design.md`, research in `docs/superpowers/specs/2026-11-17-pbs-pdm-research.md`.

## Global Constraints

- Checks are read-only; the only writes are the docs cache under `~/.cache/proxmox-skill/<product>/`.
- No dependencies beyond the product ISOs: bash, python3, coreutils, openssl. No `jq`.
- Every network call in a check has a timeout.
- Current releases: PVE 9.2, PBS 4.2, PDM 1.1, Debian 13. PBS 3.x is end of life since 2026-08 and is flagged.
- `SKILL.md` description at most 1024 characters, body under 500 lines. Everything in English.
- Skill name and install path stay `proxmox-maintenance`.
- Output conventions as today: `===== SECTION =====`, `!!` lines counted into the summary, `--` notes.
- Code style follows the existing scripts (comment the why, not the what).
- Run tests with: `python3 -m unittest discover -s tests -v`
- Commit steps propose the message; run `git commit` only after the owner's go-ahead. Work stays on branch `fix/skill-review`.

## Review Focus

1. PBS proxy not running: every `proxmox-backup-manager` call fails. Expect one warning naming the cause, not a cascade of errors per section.
2. A PBS job that never ran (no `last-run-state`): report "never run", do not crash or call it a failure.
3. PBS and PVE on one host: both product section sets run; host-level sections run once.
4. A PDM remote that hangs: the reachability call is bounded by the timeout and the check continues.
5. Empty or invalid JSON from a CLI (version mismatch, permission error): the parser prints a note and exits 0.

---

### Task 1: Collect PBS samples (owner)

The builder has no host access. Hand the owner this block to run as root on the PBS host and paste the output back.

- [ ] **Step 1: Give the owner the command block**

```bash
for c in \
  "python3 --version" \
  "dpkg-query -W -f '\${Package} \${Version} \${Status}\n' proxmox-backup-server proxmox-backup-docs pve-manager" \
  "ls /usr/share/doc/proxmox-backup/html | head -50" \
  "systemd-detect-virt" \
  "proxmox-backup-manager versions --output-format json" \
  "proxmox-backup-manager datastore list --output-format json" \
  "proxmox-backup-debug api get /status/datastore-usage --output-format json" \
  "proxmox-backup-manager garbage-collection list --output-format json" \
  "proxmox-backup-debug api get /admin/sync --output-format json" \
  "proxmox-backup-debug api get /admin/verify --output-format json" \
  "proxmox-backup-debug api get /admin/prune --output-format json" \
  "proxmox-backup-debug api get /admin/gc --output-format json" \
  "proxmox-backup-manager task list --all --limit 20 --output-format json" \
  "proxmox-backup-manager remote list --output-format json" \
  "proxmox-tape drive list --output-format json" \
  "proxmox-backup-manager cert info"; do
  printf '\n### %s\n' "$c"; eval "$c" 2>&1 | head -c 6000
done
```

- [ ] **Step 2: Save anonymised output as fixtures**

Replace hostnames, IPs, fingerprints, datastore and remote names (`store1`, `remote1`, ...), keep structure and field names. One file per command in `tests/fixtures/pbs/` (`datastore-usage.json`, `admin-sync.json`, `admin-verify.json`, `admin-prune.json`, `admin-gc.json`, `task-list.json`, `gc-list.json`). Record in the research notes any path or field that differs from them.

Tasks 2 and 3 can start before the samples arrive; Tasks 4 and 5 need them.

---

### Task 2: Restructure into per-product layout

**Files:**
- Create: `scripts/check.sh`, `scripts/checks/common.sh`, `scripts/checks/pve.sh`, `tests/test_check.py`, `tests/stubs/` (stub executables)
- Delete: `scripts/pve-check.sh`
- Move: `references/*.md` to `references/pve/` (`git mv`)
- Modify: `SKILL.md` (paths only), `README.md` (paths only)

**Interfaces:**
- Produces (common.sh): `sec NAME` (0 when the section should run), `warn MSG`, `note MSG`, `have CMD`, `product_installed pve|pbs|pdm`, `PRODUCTS` (space-separated, in order `pve pbs pdm`), `IN_CONTAINER` (0/1), `cert_expiry_days HOST:PORT` (prints days, empty on failure).
- Produces (check.sh): `check.sh [--full] [--cluster] [--product P] [--section S] [--products]`. `--products` prints `PRODUCTS` and exits 0. Host-level sections: `identity services packages certs network zfs disk smart logs`. PVE: `cluster storage guests backup`. Each product file defines one function per section, named `<product>_<section>` (e.g. `pve_cluster`).

- [ ] **Step 1: Write the failing tests** in `tests/test_check.py`. Each test runs `bash scripts/check.sh` with `PATH=tests/stubs/<case>:$PATH`, where a stub `dpkg-query` prints `install ok installed` for the listed packages.
  - `test_products_pve_only`: stubs `pve-manager` → stdout `pve`.
  - `test_products_pve_and_pbs`: stubs `pve-manager proxmox-backup-server` → stdout `pve pbs` (Review Focus 3).
  - `test_backup_client_is_not_pbs`: stubs `pve-manager proxmox-backup-client` → stdout `pve`.
  - `test_unknown_section_exits_2`: `--section stroage` → exit 2, stderr contains `unknown section`.
  - `test_section_of_missing_product_exits_2`: PVE only, `--section datastores` → exit 2, stderr contains `not installed`.

- [ ] **Step 2: Run** `python3 -m unittest tests.test_check -v` → FAIL (no `check.sh`).

- [ ] **Step 3: Implement.** Split `pve-check.sh` along the interfaces above: argument parsing and section validation in `check.sh`; helpers and host-level sections in `common.sh`; `cluster storage guests backup` in `pve.sh`. Move the ZFS pool/vdev logic into `zfs` and the root filesystem check into `disk`. Product-specific bits in host-level sections switch on `product_installed`: `pveversion`/`pvesubscription` and `interfaces.new` only for PVE; the highlighted pending-update pattern per product; `certs` uses `cert_expiry_days localhost:8006|8007|8443` per installed product (`openssl s_client` with `timeout 10`), plus the existing PVE file checks. With `IN_CONTAINER=1` (`systemd-detect-virt --container`), `smart`, `zfs`, the kernel/reboot lines of `identity` and the conflict check in `network` print a note and skip. The first block of output lists products and versions (`dpkg-query`).

- [ ] **Step 3b: Move references** with `git mv references/{diagnose,changes,upgrades}.md references/pve/`; update every path in `SKILL.md`, `README.md` and `references/pve/*.md` (`scripts/pve-check.sh` → `scripts/check.sh`, `references/` → `references/pve/`). Update `allowed-tools` to `Bash(bash ${CLAUDE_SKILL_DIR}/scripts/check.sh*)` plus the existing docs entries.

- [ ] **Step 4: Run** the tests → PASS; `bash -n scripts/check.sh scripts/checks/*.sh` → no output; `grep -rn 'pve-check' . --exclude-dir=.git` → only matches in `docs/superpowers/`.

- [ ] **Step 5: Commit** `refactor(check): split the health check per product and move references`.

---

### Task 3: Product-agnostic docs indexer

**Files:**
- Create: `scripts/docs.py` (from `git mv scripts/pve-docs.py`), `tests/test_docs.py`, `tests/fixtures/docs/asciidoc.html`, `tests/fixtures/docs/sphinx.html`
- Modify: `SKILL.md`, `references/pve/*.md` (`pve-docs.py` → `docs.py`)

**Interfaces:**
- Produces: `PRODUCTS: dict[str, Product]` where `Product` holds `docs_dir: Path`, `version_pkg: str`, `docs_pkg: str`, `notes_url: str | None` (`None` for PDM). `installed_products() -> list[str]`. `parse_sections(html: str) -> list[dict]` with keys `anchor`, `title`, `text`. CLI: `docs.py [--product P] status|sync|search|show|online-path`; with several products, `search` covers all and ids get a `<product>:` prefix.

- [ ] **Step 1: Write the failing tests** in `tests/test_docs.py` against the two fixtures (write them by hand: a trimmed asciidoc page with `<h3 id="_bind_mount_points">`, and a Sphinx page with the markup from the research notes, a `div.sphinxsidebar` holding `<h3>Quick search</h3>`, and a headerlink `¶`).
  - `test_asciidoc_anchor`: a section with anchor `_bind_mount_points`.
  - `test_sphinx_anchor_from_section_id`: a section with anchor `pruning` and title `Pruning`.
  - `test_sphinx_title_has_no_pilcrow`: no title contains `¶`.
  - `test_sphinx_sidebar_ignored`: no title equals `Quick search`.
  - `test_skipped_pages`: `source_files()` on a temp dir with `genindex.html search.html index.html storage.html` returns only `storage.html`.
  - `test_pdm_has_no_online_notes`: `PRODUCTS["pdm"].notes_url is None`.

- [ ] **Step 2: Run** `python3 -m unittest tests.test_docs -v` → FAIL.

- [ ] **Step 3: Implement.** Product table values from the spec. Version and docs version via `dpkg-query -W -f '${Version}'` (drop `pveversion`). Cache under `CACHE_DIR / product`. In `SectionParser`: drop `¶` from titles, track and skip `div.sphinxsidebar` subtrees. `source_files` skips `index.html`, `genindex.html`, `search.html` and `pve-admin-guide*`. `status` for PDM says release notes are local in `roadmap.html` and never reports them MISSING. Release-notes URLs: PVE `https://pve.proxmox.com/wiki/Roadmap#Proxmox_VE_<X.Y>` and `#<X.Y>-known-issues`; PBS `https://pbs.proxmox.com/wiki/Roadmap#Proxmox_Backup_Server_<X.Y>` and `#<X.Y>-known-issues`.

- [ ] **Step 4: Run** the tests → PASS.

- [ ] **Step 5: Commit** `feat(docs): index the local manuals of PVE, PBS and PDM`.

---

### Task 4: PBS checks

**Files:**
- Create: `scripts/checks/pbs.sh`, `scripts/checks/json_report.py`, `tests/test_json_report.py`, fixtures from Task 1

**Interfaces:**
- Consumes: common.sh helpers (Task 2).
- Produces: sections `datastores gc jobs tasks remotes tape` as `pbs_<section>`. `json_report.py <report>` reads JSON on stdin and prints one finding per line, prefixed `WARN ` or `NOTE `; exit 0 always. Reports: `pbs-usage` (stores above 85%), `pbs-jobs` (failed or never-run jobs), `pbs-tasks` (failed tasks), `pbs-gc` (last GC failed or never ran).

- [ ] **Step 1: Write the failing tests** in `tests/test_json_report.py` using the Task 1 fixtures. Expected findings follow from the fixture contents; in addition:
  - `test_job_without_last_run_state_is_never_run`: input `[{"id": "job1", "store": "store1"}]` to `pbs-jobs` → `NOTE job1 (store1) has never run` (Review Focus 2).
  - `test_failed_job_is_warning`: input with `"last-run-state": "connection refused"` → line starts with `WARN` and contains the state.
  - `test_invalid_json_is_a_note`: input `not json` → one `NOTE` line, exit 0 (Review Focus 5).
  - `test_usage_above_85_percent`: `[{"store": "store1", "total": 100, "used": 90}]` to `pbs-usage` → `WARN store1 is 90% full`.

- [ ] **Step 2: Run** `python3 -m unittest tests.test_json_report -v` → FAIL.

- [ ] **Step 3: Implement `json_report.py`** with the field names confirmed by the fixtures (expected: `last-run-state`, `last-run-endtime`, `next-run`, `store`, `total`, `used`).

- [ ] **Step 4: Implement `pbs.sh`.** Before the first section, probe the API once (`proxmox-backup-manager versions` with `timeout 20`); on failure warn once that `proxmox-backup-proxy` is not reachable and skip all PBS sections (Review Focus 1). Map `WARN`/`NOTE` lines from `json_report.py` to `warn`/`note`. `datastores` also reports maintenance mode from `datastore list`. `tape` only when `proxmox-tape drive list` returns entries. Warn when `proxmox-backup-server` is 3.x: end of life since 2026-08, see `pbs3to4`.

- [ ] **Step 5: Run** all tests → PASS; `bash -n scripts/checks/pbs.sh`.

- [ ] **Step 6: Owner verification.** The owner runs `bash scripts/check.sh --product pbs` on the PBS host and pastes the output; fix what differs.

- [ ] **Step 7: Commit** `feat(pbs): add Proxmox Backup Server health checks`.

---

### Task 5: PBS references

**Files:**
- Create: `references/pbs/diagnose.md`, `references/pbs/changes.md`, `references/pbs/upgrades.md`

- [ ] **Step 1: Write** the three files in the shape of the PVE ones (Contents section when over 100 lines, commands first, causes ranked, doc ids cited as `python3 <skill-dir>/scripts/docs.py search ...`). Sources: research notes and the PBS docs pages listed there; anything not confirmed by docs or samples gets left out, not guessed. Diagnose covers the five failure modes from the research notes; changes covers datastores (maintenance mode, removable stores), prune/GC/verify/sync jobs and remotes; upgrades covers minor updates and 3 to 4 with `pbs3to4 --full` and read-only maintenance mode.

- [ ] **Step 2: Verify** every command in the files appears in the research notes or the Task 1 samples: `grep -oE '^(proxmox-backup-[a-z]+|proxmox-tape|pbs3to4)[^#]*' references/pbs/*.md` and check each by hand.

- [ ] **Step 3: Commit** `docs(pbs): add diagnose, change and upgrade references`.

---

### Task 6: PDM checks and references

No PDM host is available; everything here is built from the docs and marked untested in the commit body and the README.

**Files:**
- Create: `scripts/checks/pdm.sh`, `references/pdm/diagnose.md`, `references/pdm/changes.md`, `references/pdm/upgrades.md`
- Modify: `tests/test_check.py`, `scripts/checks/json_report.py`, `tests/test_json_report.py`

**Interfaces:**
- Produces: sections `remotes subscriptions` as `pdm_<section>`; `json_report.py pdm-remotes` prints one remote id per line (prefixed `ID `).

- [ ] **Step 1: Write the failing tests.**
  - `test_pdm_remote_timeout` in `tests/test_check.py`: stub `proxmox-datacenter-manager-admin` (`remote list` returns one remote), stub `timeout` that appends its arguments to a file and runs the command; `--section remotes` on a PDM-only stub host → the recorded arguments start with `15` (Review Focus 4).
  - `test_pdm_remote_ids` in `tests/test_json_report.py`: `[{"id": "pve1", "type": "pve"}]` → `ID pve1`.

- [ ] **Step 2: Run** → FAIL.

- [ ] **Step 3: Implement.** `remotes`: list, then `timeout 15 proxmox-datacenter-manager-admin remote version <id>` per remote; non-zero exit warns with the hint `probe-certificate` / `set-fingerprint`. `subscriptions`: `remote subscriptions --output-format json`; the 80% rule as a note; unparseable output is a note. The services section (Task 2) includes the PDM units and `proxmox-datacenter-manager-daily-update.timer`.

- [ ] **Step 4: Write the references** like Task 5, from the research notes; PDM release notes point at the local `roadmap.html`.

- [ ] **Step 5: Run** all tests → PASS.

- [ ] **Step 6: Commit** `feat(pdm): add Datacenter Manager checks and references` with a body stating it is untested on a real host.

---

### Task 7: SKILL.md and README for three products

**Files:**
- Modify: `SKILL.md`, `README.md`

- [ ] **Step 1: Rewrite the description** to name PVE, PBS and PDM and their typical symptoms (datastore full, GC, verify, sync, remotes, fingerprints). Check length: `python3 -c` snippet as before → at most 1024.

- [ ] **Step 2: Rewrite the body.** Shared method unchanged; a section "Which product" telling Claude to read the detected-products block of `check.sh` (or run `check.sh --products`) and load `references/<product>/`; a must-know list per product (PVE: the four existing findings; PBS: prune frees nothing until GC, GC needs atime/relatime, fingerprint changes break PVE storage and sync remotes; PDM: pinned fingerprints, unreachable remotes, the 80% subscription rule). `allowed-tools` lists `check.sh*` and `docs.py status*|search*|show*`.

- [ ] **Step 3: README.** Three products in the intro and the "What is inside" table; benchmark figures labelled as measured on PVE only; PDM marked untested on a real host.

- [ ] **Step 4: Verify** `wc -l SKILL.md` under 500; `grep -rn 'pve-docs.py\|pve-check.sh' SKILL.md README.md references scripts` → no output.

- [ ] **Step 5: Commit** `docs(skill): describe PVE, PBS and PDM`.
