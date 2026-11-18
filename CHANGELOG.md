# Changelog

## [1.1.0](https://github.com/jeroenzwart/proxmox-maintenance-skill/compare/v1.0.0...v1.1.0) (2026-11-18)


### Features

* **check:** add a security audit section ([72a9e52](https://github.com/jeroenzwart/proxmox-maintenance-skill/commit/72a9e527d8e0f20533380bdf9de754c5756f4587))
* **check:** add an update readiness section ([5c5cda5](https://github.com/jeroenzwart/proxmox-maintenance-skill/commit/5c5cda5aed2830e7d95d715d189d7e4a445e847a))
* **check:** add JSON output ([1374c30](https://github.com/jeroenzwart/proxmox-maintenance-skill/commit/1374c300ac1e6283450820f1e77c6ab92e14ec0e))
* **check:** check that failures notify someone ([7cb8472](https://github.com/jeroenzwart/proxmox-maintenance-skill/commit/7cb8472717fa3ce2291f52423637ee820e60063e))
* **check:** compare a run with the previous one ([c77506b](https://github.com/jeroenzwart/proxmox-maintenance-skill/commit/c77506b1ecd0b288ba45e40fa09d727d281c6e76))
* **docs:** index the local manuals of PVE, PBS and PDM ([9fe5e06](https://github.com/jeroenzwart/proxmox-maintenance-skill/commit/9fe5e0616e60823be9f35b5f67570186886665e5))
* **pdm:** add Datacenter Manager checks and references ([a344af4](https://github.com/jeroenzwart/proxmox-maintenance-skill/commit/a344af4a6adf2f19161b32426cee39c350a2f01a))
* **pve:** add a Ceph health summary ([f785d11](https://github.com/jeroenzwart/proxmox-maintenance-skill/commit/f785d11a89a83b11836f89772c64d34e987f6ea3))
* **pve:** check replication jobs and HA states ([c93e635](https://github.com/jeroenzwart/proxmox-maintenance-skill/commit/c93e6356cdc1f33e98db9283fc6392660cea2dbc))
* **pve:** report guests without recent backups and forgotten snapshots ([94451c7](https://github.com/jeroenzwart/proxmox-maintenance-skill/commit/94451c7450dbbec07f46491bdda868ad8f17c0d4))


### Bug Fixes

* **check:** address the phase 2 review findings ([da759b8](https://github.com/jeroenzwart/proxmox-maintenance-skill/commit/da759b82fbe6325d2aa0b66e12f8cc45427376aa))
* **check:** print the whole header for --help ([25af6c6](https://github.com/jeroenzwart/proxmox-maintenance-skill/commit/25af6c61302aedce37ff5b65c13744c7e048040b))
* **pve-check:** correct false alarms and per-vdev redundancy reporting ([5527685](https://github.com/jeroenzwart/proxmox-maintenance-skill/commit/5527685d059eb1ee16d0404d3f5dfdf11d3f9874))
* **test:** register docs.py in sys.modules before loading it ([043e670](https://github.com/jeroenzwart/proxmox-maintenance-skill/commit/043e670bf4e4cf3560330e1c386b25c0f878e1db))
