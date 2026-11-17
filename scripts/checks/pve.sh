# Proxmox VE sections for check.sh. Sourced, not run.
#
# Expensive commands (pvecm/pvesm) are run at most once and reused. Besides
# being faster, that removes a class of false alarms: a second call to a busy
# pvecm can time out and return nothing, which then reads as "cluster not
# quorate" when the cluster is perfectly fine.

_pvecm=""; _pvecm_done=0
pvecm_status() {
  [ "$_pvecm_done" = 1 ] || { _pvecm="$(timeout 25 pvecm status 2>&1)"; _pvecm_done=1; }
  printf '%s\n' "$_pvecm"
}
_pvesm=""; _pvesm_done=0
pvesm_status() {
  [ "$_pvesm_done" = 1 ] || { _pvesm="$(timeout 60 pvesm status 2>&1)"; _pvesm_done=1; }
  printf '%s\n' "$_pvesm"
}
pve_cluster() {
  sec cluster || return 0
  if [ -e /etc/pve/corosync.conf ]; then
    st="$(pvecm_status)"
    echo "$st" | sed 's/^/  /' | head -40
    quorate="$(echo "$st" | awk -F': *' '/^Quorate/{print $2; exit}' | tr -d ' \r')"
    nodes_n="$(echo "$st" | awk -F': *' '/^Nodes:/{print $2; exit}' | tr -d ' \r')"
    votes="$(echo "$st" | awk -F': *' '/Expected votes/{print $2; exit}' | tr -d ' \r')"
    has_qdev=0
    grep -qE 'quorum_device|device \{' /etc/pve/corosync.conf 2>/dev/null && has_qdev=1
    # The membership block of `pvecm status` lists ring addresses, which are
    # IPs whenever corosync was configured that way, so it cannot be compared
    # against directory names. corosync.conf always carries the node names.
    members="$(awk -F': *' '/^[[:space:]]*name:/{print $2}' /etc/pve/corosync.conf 2>/dev/null | tr -d ' \r')"
    [ -z "$members" ] && members="$(timeout 20 pvecm nodes 2>/dev/null | awk 'NR>3 && $3!="Name"{print $3}' | tr -d ' ')"
    # "Nodes:" in pvecm status counts only the members online right now, so it
    # cannot tell a two-node cluster from a three-node one with a node down.
    member_count="$(echo "$members" | grep -c .)"

    if [ -z "$quorate" ]; then
      warn "could not read quorum state from pvecm (is corosync running?)"
    elif [ "$quorate" != "Yes" ]; then
      warn "cluster is NOT quorate - /etc/pve stays read-only until quorum returns"
    else
      note "quorate: yes (${nodes_n:-?} of $member_count nodes online, expected votes ${votes:-?})"
    fi
    if [ "$member_count" = "2" ] && [ "$has_qdev" = "0" ]; then
      warn "2-node cluster without a QDevice: with expected votes ${votes:-2}, taking ONE node down leaves the survivor without quorum and /etc/pve read-only. Reboot/upgrade one node at a time and bring it fully back before touching the other, or add a QDevice as a third vote."
    fi

    echo
    echo "  -- node directories vs cluster members --"
    echo "  members per corosync.conf: $(echo "$members" | tr '\n' ' ')"
    for d in /etc/pve/nodes/*/; do
      n="$(basename "$d")"
      if echo "$members" | grep -qx "$n"; then
        note "$n: live member"
      else
        empty="$(find "$d" -type f 2>/dev/null | wc -l)"
        warn "/etc/pve/nodes/$n is not a live cluster member ($empty config files inside) - stale leftover or a case-mismatched duplicate of an existing node"
      fi
    done
    if have corosync-cfgtool; then
      echo "  -- corosync links --"
      timeout 15 corosync-cfgtool -s 2>&1 | sed 's/^/  /' | head -20
    fi
  else
    note "standalone host (no corosync.conf)"
  fi
  if [ -w /etc/pve ]; then note "/etc/pve is writable"; else warn "/etc/pve is READ-ONLY (no quorum, or pve-cluster is down)"; fi
}

pve_storage() {
  sec storage || return 0
  ps_out="$(pvesm_status)"
  echo "$ps_out" | sed 's/^/  /'
  echo
  # A disabled storage was taken out of use on purpose, so it is not a fault.
  echo "$ps_out" | awk 'NR>1 && $3!="active" && $3!="disabled"{print "  !! storage "$1" ("$2") is "$3}'
  inactive="$(echo "$ps_out" | awk 'NR>1 && $3!="active" && $3!="disabled"' | wc -l)"
  [ "$inactive" -gt 0 ] && WARN_COUNT=$((WARN_COUNT + inactive))
  while read -r line; do
    [ -n "$line" ] && warn "$line"
  done < <(echo "$ps_out" | awk 'NR>1 {gsub(/%/,"",$7); if ($7+0 > 85) print "storage "$1" is "$7"% full"}')

  # A storage limited to certain nodes silently pins every guest that uses it:
  # the guest cannot migrate, and it cannot be restored elsewhere. That is easy
  # to forget when planning a reboot or an evacuation.
  restricted="$(awk '/^[a-z]+: /{s=$2} /^[[:space:]]+nodes /{print "    "s" -> only on: "$2}' /etc/pve/storage.cfg 2>/dev/null)"
  if [ -n "$restricted" ]; then
    echo "  -- node-restricted storages --"
    echo "$restricted"
    note "guests using these storages cannot migrate to, or be restored on, other nodes"
  fi
}

pve_guests() {
  sec guests || return 0
  echo "  -- VMs --"
  timeout 60 qm list 2>&1 | sed 's/^/  /'
  echo "  -- containers --"
  timeout 60 pct list 2>&1 | sed 's/^/  /'
  # A leftover 'lock:' in a guest config is the usual fingerprint of a backup
  # or migration that died halfway; the guest then refuses to start.
  while read -r f; do
    [ -z "$f" ] && continue
    id="$(basename "$f" .conf)"
    lock="$(grep -m1 '^lock:' "$f" | cut -d' ' -f2)"
    warn "guest $id is locked ('$lock' in $f) - a task probably aborted; clear with 'qm unlock $id' / 'pct unlock $id' once you are sure nothing is still running"
  done < <(grep -l '^lock:' /etc/pve/qemu-server/*.conf /etc/pve/lxc/*.conf 2>/dev/null)
  if have ha-manager; then
    ha="$(timeout 20 ha-manager status 2>/dev/null)"
    [ -n "$ha" ] && { echo "  -- HA --"; echo "$ha" | sed 's/^/  /'; }
  fi
}

pve_backup() {
  sec backup || return 0
  if [ -f /etc/pve/jobs.cfg ]; then
    echo "  -- configured backup jobs --"
    sed 's/^/  /' /etc/pve/jobs.cfg
  else
    warn "no /etc/pve/jobs.cfg - no scheduled backup jobs are defined on this cluster"
  fi
  echo "  -- recent backup tasks --"
  idx=/var/log/pve/tasks/index
  if [ -f "$idx" ]; then
    grep -h 'vzdump' "$idx" 2>/dev/null | tail -10 | sed 's/^/  /'
    fails="$(grep -h 'vzdump' "$idx" 2>/dev/null | tail -40 | grep -cvE ' OK$')"
    [ "${fails:-0}" -gt 0 ] && warn "$fails of the last 40 backup tasks did not end in OK - inspect with 'pvenode task log <UPID>'"
  else
    note "no task index at $idx"
  fi
  pvesm_status | awk '$2=="pbs"{print "  -- PBS storage "$1": "$3", "$7" used"}'

  # vzdump never captures the contents of a bind mount - only storage-backed
  # volumes. A backup job reporting OK every night therefore says nothing about
  # the host directories mounted into guests, which is usually where the bulk
  # of the irreplaceable data lives.
  echo "  -- bind mounts (NOT covered by vzdump/PBS) --"
  binds="$(grep -hE '^mp[0-9]+: */' /etc/pve/lxc/*.conf 2>/dev/null | sed -E 's/,.*//; s/^mp[0-9]+: *//' | sort -u)"
  if [ -n "$binds" ]; then
    n_b="$(echo "$binds" | grep -c .)"
    echo "$binds" | sed 's/^/    /'
    total=""
    # df on the full path: its first component (/mnt, /tank) is usually a
    # different filesystem or the parent dataset, not the one that is mounted.
    while read -r b; do
      [ -d "$b" ] || continue
      sz="$(df -h --output=used "$b" 2>/dev/null | tail -1 | tr -d ' ')"
      [ -n "$sz" ] && total="$total $b=$sz"
    done <<< "$binds"
    warn "$n_b distinct bind mount source path(s) are mounted into containers; vzdump/PBS does NOT back up their contents.${total:+ Filesystem usage:$total} Verify these are protected some other way (zfs send, a separate backup client, or a replica) - a nightly job reporting OK covers only the guests themselves."
  else
    note "no bind mounts configured; guest data lives on storage-backed volumes only"
  fi
}

pve_cluster_sweep() {
  [ -e /etc/pve/corosync.conf ] || return 0
  for d in /etc/pve/nodes/*/; do
    n="$(basename "$d")"
    [ "$n" = "$NODE" ] && continue
    printf '\n########## remote node: %s ##########\n' "$n"
    if ! timeout 20 ssh -o BatchMode=yes -o ConnectTimeout=8 "$n" true 2>/dev/null; then
      note "$n not reachable over SSH - skipped (if it is a stale node directory, see the cluster section)"
      continue
    fi
    remote_host="$(timeout 20 ssh -o BatchMode=yes "$n" hostname 2>/dev/null)"
    if [ "$remote_host" = "$NODE" ]; then
      warn "ssh '$n' resolves back to this host ($NODE) - the name does not point at the other node, so its state was NOT checked"
      continue
    fi
    timeout 90 ssh -o BatchMode=yes -o ConnectTimeout=8 "$n" '
      echo "hostname: $(hostname)"
      echo "uptime  :$(uptime -p | sed "s/^up//")"
      pveversion
      echo "kernel  : $(uname -r)"
      echo "updates : $(apt list --upgradable 2>/dev/null | tail -n +2 | grep -c .) upgradable"
      echo "failed  : $(systemctl --failed --no-legend | grep -c .) failed units"
      command -v zpool >/dev/null 2>&1 && zpool status -x
      df -h / | tail -1
    ' 2>&1 | sed 's/^/  /'
  done
}
