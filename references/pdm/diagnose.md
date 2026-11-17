# Diagnosing Proxmox Datacenter Manager

Read this when PDM shows a remote as unavailable, the web UI does not load, or
updates fail. PDM is a management layer: most of its problems are really about
reaching a remote PVE or PBS, not about PDM itself.

Built from the PDM 1.1 documentation; not yet verified on a real PDM host.
Confirm commands with `python3 <skill-dir>/scripts/docs.py --product pdm search <terms>`
before relying on their exact output.

```bash
proxmox-datacenter-manager-admin versions
proxmox-datacenter-manager-admin remote list
proxmox-datacenter-manager-admin remote version <remote-id>   # contacts the remote
systemctl status proxmox-datacenter-api proxmox-datacenter-privileged-api
journalctl -u proxmox-datacenter-api --since '1 hour ago' --no-pager
ls /var/log/proxmox-datacenter-manager/
```

The admin CLI runs as root and calls the API handlers in-process. There is no
task list in either CLI; read the journal or the log directory instead.

## A remote shows as unavailable

Causes, roughly in order of how often they are the real one:

- **The remote renewed its certificate.** PDM pins each remote's certificate
  fingerprint, so after a renewal every connection fails with "certificate
  verify failed". Probe the new certificate with
  `proxmox-datacenter-manager-client remote probe-certificate <remote> <node>`
  (the client needs a `login` first), compare the fingerprint with the one the
  remote reports, then update it with the client's `set-fingerprint`. Check the
  exact syntax in the docs first: `docs.py --product pdm search fingerprint`.
- **The remote is down or unreachable** from the PDM host: test the transport
  directly (`ping`, `curl -k https://<remote>:8006` for PVE, `:8007` for PBS)
  before touching PDM.
- **The API token was revoked or lost its permissions** on the remote side.
  The remote's own task log and auth log show the rejected requests.

## Web UI does not load

The web UI is HTTPS on port 8443.

```bash
systemctl is-active proxmox-datacenter-api proxmox-datacenter-privileged-api
ss -tlnp | grep 8443
proxmox-datacenter-manager-admin cert info
```

Common causes: one of the two API daemons is down, the certificate expired
(an ACME renewal that failed silently), or a full root filesystem.

## Updates fail or the enterprise repository is refused

PDM has no subscription of its own. Access to its enterprise repository
requires that at least 80% of the remote nodes it manages have a Basic or
higher subscription. `proxmox-datacenter-manager-admin remote subscriptions`
shows the state per remote. Without that, use the no-subscription repository.

## Scripts against the API broke after an update

The API changed between 1.0 releases, for example `/remotes/{id}` moved to
`/remotes/remote/{id}`. Read the breaking changes for the installed version in
the local roadmap: `docs.py --product pdm search known issues breaking changes`.
