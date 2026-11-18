# Proxmox Datacenter Manager sections for check.sh. Sourced, not run.
#
# Built from the PDM 1.1 documentation; not yet verified on a real PDM host.

pdm_remotes() {
  local listing ids id
  sec remotes || return 0
  listing="$(timeout 30 proxmox-datacenter-manager-admin remote list --output-format json 2>&1)"
  ids="$(echo "$listing" | python3 "$SCRIPT_DIR/checks/json_report.py" pdm-remotes)"
  report_lines < <(echo "$ids" | grep -v '^ID ')
  ids="$(echo "$ids" | awk '$1 == "ID" {print $2}')"
  if [ -z "$ids" ]; then
    note "no remotes configured"

    return 0
  fi
  # Every remote is contacted, so each call is bounded: one hanging remote
  # must not stall the whole check.
  for id in $ids; do
    if timeout 15 proxmox-datacenter-manager-admin remote version "$id" >/dev/null 2>&1; then
      printf '  %-24s reachable\n' "$id"
    else
      warn "remote $id did not answer within 15s - unreachable, revoked token, or a certificate change; if the remote renewed its certificate, use 'proxmox-datacenter-manager-client remote probe-certificate' and 'set-fingerprint'"
    fi
  done
}

pdm_subscriptions() {
  sec subscriptions || return 0
  timeout 60 proxmox-datacenter-manager-admin remote subscriptions 2>&1 | head -40 | sed 's/^/  /'
  note "the PDM enterprise repository needs at least 80% of the remote nodes on a Basic or higher subscription"
}
