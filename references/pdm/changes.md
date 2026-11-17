# Making changes on Proxmox Datacenter Manager

Read this before changing PDM's configuration. Built from the PDM 1.1
documentation; not yet verified on a real PDM host. Look up exact syntax with
`python3 <skill-dir>/scripts/docs.py --product pdm search <terms>` before
running a command you have not seen work here.

The general shape of a safe change is the same as on any Proxmox host: know
the current state, write down how to get back to it, make the smallest change,
verify it.

```bash
proxmox-datacenter-manager-admin remote list --output-format json > /root/pdm-remotes-$(date +%F).json
cp -a /etc/proxmox-datacenter-manager /root/pdm-config-$(date +%F)
```

## Remotes

- **Adding a remote** is done in the web UI or with
  `proxmox-datacenter-manager-client`. It needs an API token on the remote
  with the permissions the docs list; use a dedicated token per PDM instance
  so it can be revoked on its own.
- **Updating a pinned fingerprint** after a remote renewed its certificate:
  probe first (`proxmox-datacenter-manager-client remote probe-certificate
  <remote> <node>`), compare the fingerprint with what the remote itself
  reports, and only then set it. Setting a fingerprint you did not verify
  removes the protection the pin exists for.
- **Removing a remote** from PDM is meant to drop PDM's view of it, not the
  remote itself; confirm that in the docs for the installed version before
  relying on it.

## Certificates

`proxmox-datacenter-manager-admin cert info` shows PDM's own certificate. The
`acme` subcommand manages ACME accounts and renewal; check the renewal after
any DNS or firewall change, because a failed renewal only shows once the
certificate expires.

## Operations that deserve extra care

- **Any change to the API token of a remote** cuts PDM off from it until the
  new token is configured on both sides.
- **Bulk actions on remotes from PDM** (migrations, shutdowns) act on the
  remote clusters; treat them with the same care as running the command on
  that cluster, including its quorum and backup checks.
