# Research notes: PBS and PDM (2026-11-17)

Collected from Proxmox's own sites and git.proxmox.com packaging. Items marked
*unverified* still need checking on a real host. Input for the references and
checks described in `2026-11-17-multi-product-design.md`.

## Proxmox Backup Server

- **Release:** 4.2 (2026-04-29), Debian 13.4. PBS 3 (Bookworm) is end of life
  since 2026-08. Source: pbs.proxmox.com/wiki/Roadmap,
  `docs/faq-release-support-table.csv`.
- **Local docs:** package `proxmox-backup-docs` (hard dependency of
  `proxmox-backup-server`), HTML in `/usr/share/doc/proxmox-backup/html/`,
  Sphinx, one page per chapter (storage, maintenance, backup-client,
  managing-remotes, tape-backup, sysadmin, pve-integration, ...). Skip
  `genindex.html`, `search.html`, `index.html`; subfolders (api-viewer,
  prune-simulator, lto-barcode) are not `*.html` at top level.
- **Sphinx markup:** `<section id="pruning"><span id="maintenance-pruning"></span>
  <h2>Pruning<a class="headerlink">¶</a></h2>`. Headings carry no id; the
  section id is the anchor. Strip `¶`; ignore `div.sphinxsidebar`.
- **Version:** `proxmox-backup-manager versions [--output-format json]`,
  `dpkg-query -W -f '${Version}' proxmox-backup-server`.
- **Detection:** package `proxmox-backup-server`; units `proxmox-backup`,
  `proxmox-backup-proxy`. Not `proxmox-backup-client` (present on every PVE
  host). Co-install on PVE is documented but "not recommended".
- **Read-only commands (root; need the proxy running, API on localhost:8007):**
  - `proxmox-backup-manager datastore list`
  - `proxmox-backup-debug api get /status/datastore-usage --output-format json`
  - `proxmox-backup-manager garbage-collection list` / `status <store>`
  - `proxmox-backup-debug api get /admin/{sync,verify,prune,gc}` (last-run state)
  - `proxmox-backup-manager {sync,verify,prune}-job list` (config only)
  - `proxmox-backup-manager task list --all --limit N`, `task log <UPID>`
  - `proxmox-backup-manager subscription get`, `cert info`, `remote list`,
    `disk list`, `report`
  - Tape: `proxmox-tape drive list`, `changer list`, `pool list`
- **Release notes:** `pbs.proxmox.com/wiki/Roadmap#Proxmox_Backup_Server_<X.Y>`,
  `#<X.Y>-known-issues`.
- **Upgrade:** wiki `Upgrade_from_3_to_4`, checker `pbs3to4 --full`; put
  datastores in read-only maintenance mode during the upgrade.
- **Web UI:** HTTPS 8007.
- **Failure modes:** datastore full or GC not running (prune frees nothing;
  GC removes chunks with atime older than 24h5m, needs atime/relatime);
  verify failures (`.bad` chunks; fix by re-sync or new backup); certificate
  fingerprint change breaks PVE `storage.cfg` and sync remotes (`cert info |
  grep Fingerprint`); chunk store ownership (*unverified* wording) and
  removable datastores stuck in "unmounting"; PBS 3 past end of life.

## Proxmox Datacenter Manager

- **Release:** 1.1 (2026-05-28), Debian 13.5. 1.0 was 2025-12-04.
  Source: pdm.proxmox.com/docs/roadmap.html.
- **Local docs:** package `proxmox-datacenter-manager-docs` (dependency of the
  server), HTML in `/usr/share/doc/proxmox-datacenter-manager/html/`, same
  Sphinx layout; includes `roadmap.html`, so release notes are local.
- **Version:** `proxmox-datacenter-manager-admin versions [--output-format json]`,
  `dpkg-query -W -f '${Version}' proxmox-datacenter-manager`.
- **Detection:** package `proxmox-datacenter-manager`; units
  `proxmox-datacenter-api`, `proxmox-datacenter-privileged-api`, timer
  `proxmox-datacenter-manager-daily-update.timer`. Co-install on PVE:
  *unverified*.
- **Read-only commands (root, `proxmox-datacenter-manager-admin`):**
  `remote list`, `remote version <id>` (contacts the remote),
  `remote subscriptions`, `cert info` (text only), `support-status get`,
  `report`. No task list in either CLI; task log layout under
  `/var/log/proxmox-datacenter-manager/` *unverified*.
- **Release notes:** `roadmap.html#proxmox-datacenter-manager-<X>-<Y>`,
  `#known-issues-breaking-changes-<X>-<Y>`.
- **Upgrades:** minor updates are normal updates; `pdmAtoB` covers 0.x to 1.x.
- **Web UI:** HTTPS 8443.
- **Failure modes:** pinned fingerprint mismatch after a remote renews its
  certificate (`probe-certificate`, then `set-fingerprint`); remote
  unreachable or token revoked; enterprise repo needs 80% of remote nodes on
  Basic or higher; API daemons down or own certificate/ACME expired; API
  changes since 1.0 break old scripts.
