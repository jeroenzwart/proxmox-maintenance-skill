#!/usr/bin/env bash
# Read-only health snapshot of a Proxmox VE host (and optionally its cluster).
#
# Every command here only observes: nothing is started, stopped, installed or
# written. That is deliberate - this runs first, before any diagnosis, so the
# conclusions rest on what the machine actually reports rather than on
# assumptions about how it was set up.
#
# Expensive commands (pvecm/pvesm/apt/qm/pct) are run at most once and reused.
# Besides being faster, that removes a class of false alarms: a second call to
# a busy pvecm can time out and return nothing, which then reads as "cluster
# not quorate" when the cluster is perfectly fine.
#
# Usage: pve-check.sh [--full] [--cluster] [--section NAME]
#   --full          also read recent journal errors (slower)
#   --cluster       repeat the core checks on the other cluster nodes via SSH
#   --section NAME  run only one section: identity cluster storage guests
#                   backup services packages certs network logs smart

set -uo pipefail

FULL=0
CLUSTER=0
ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --full) FULL=1 ;;
    --cluster) CLUSTER=1 ;;
    --section) ONLY="${2:-}"; shift ;;
    --section=*) ONLY="${1#*=}" ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

# A mistyped section would run nothing and then report "no warnings raised",
# which reads as a clean bill of health.
case "$ONLY" in
  ""|identity|cluster|storage|guests|backup|services|packages|certs|network|logs|smart) ;;
  *) echo "unknown section: $ONLY" >&2; exit 2 ;;
esac

WARN_COUNT=0
NODE="$(hostname)"

sec() {
  [ -n "$ONLY" ] && [ "$ONLY" != "$1" ] && return 1
  printf '\n===== %s =====\n' "$(echo "$1" | tr '[:lower:]' '[:upper:]')"
  return 0
}
warn() { WARN_COUNT=$((WARN_COUNT + 1)); printf '  !! %s\n' "$*"; }
note() { printf '  -- %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# --- memoised readers -----------------------------------------------------
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
_apt=""; _apt_done=0
apt_upgradable() {
  [ "$_apt_done" = 1 ] || { _apt="$(timeout 60 apt list --upgradable 2>/dev/null | tail -n +2)"; _apt_done=1; }
  printf '%s\n' "$_apt"
}

# --------------------------------------------------------------------------
if sec identity; then
  echo "node        : $NODE"
  echo "date        : $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "uptime      :$(uptime -p 2>/dev/null | sed 's/^up//')"
  pveversion 2>/dev/null || echo "pveversion: not a PVE host?"
  echo "debian      : $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
  running_kernel="$(uname -r)"
  newest="$(dpkg -l 'proxmox-kernel-*-pve-signed' 2>/dev/null | awk '/^ii/{print $3}' | sort -V | tail -1)"
  echo "kernel      : running $running_kernel | newest installed ${newest:-unknown}"
  # A running kernel older than the newest installed one usually means a
  # pending reboot - but not when someone deliberately pinned an older kernel.
  # Reporting a pin as "reboot pending" would push the user to undo a choice
  # they made on purpose, so read the pin before drawing that conclusion.
  pinned=""
  have proxmox-boot-tool && pinned="$(timeout 20 proxmox-boot-tool kernel list 2>/dev/null | awk '/Pinned kernel/{getline; print}' | tr -d ' \r')"
  if [ -n "$pinned" ] && [ "$pinned" != "None." ]; then
    echo "kernel pin  : $pinned"
    if [ "$pinned" = "$running_kernel" ]; then
      note "the running kernel is pinned deliberately - newer kernels stay installed but unused until 'proxmox-boot-tool kernel unpin'. Do not treat this as a missed reboot."
      [ -n "$newest" ] && [ "${running_kernel%-pve}" != "$newest" ] && note "a newer kernel ($newest) is available once the pin is lifted"
      # proxmox-kernel-helper shields the pinned kernel from autoremove through
      # APT::NeverAutoRemove, but only once a refresh has rewritten that list.
      apt_keep=/etc/apt/apt.conf.d/76pveconf
      if [ -f "$apt_keep" ] && ! tr -d '\\' < "$apt_keep" | grep -qF "${pinned%-pve}"; then
        warn "pinned kernel $pinned is missing from APT::NeverAutoRemove in $apt_keep - 'apt autoremove' may remove it; run 'proxmox-boot-tool refresh'"
      fi
    else
      warn "kernel $pinned is pinned but $running_kernel is running - the pin did not take effect; check proxmox-boot-tool refresh"
    fi
  elif [ -n "$newest" ] && [ "${running_kernel%-pve}" != "$newest" ]; then
    warn "newer kernel installed ($newest) than the one running ($running_kernel) and no pin is set - a reboot is pending"
  fi
  if have pvesubscription; then
    sub="$(timeout 15 pvesubscription get 2>/dev/null | awk -F': *' '/^status/{print $2}')"
    echo "subscription: ${sub:-unknown}"
  fi
fi

# --------------------------------------------------------------------------
if sec cluster; then
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
fi

# --------------------------------------------------------------------------
if sec storage; then
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

  if have zpool; then
    echo "  -- zfs pools --"
    zpool list 2>/dev/null | sed 's/^/  /'
    # ZFS does not fill vdevs evenly, so a comfortable pool-level percentage can
    # hide a vdev that is nearly full - which slows writes and lengthens any
    # resilver exactly when that matters most.
    # Vdev CAP has a decimal while pool CAP is whole, so a single-vdev pool
    # needs the +1 margin to not report its only vdev as fuller than the pool.
    while read -r kind name cap pool_cap; do
      case "$kind" in
        pool) warn "pool $name is ${cap}% full - ZFS slows down sharply above ~80% and refuses writes near 100%" ;;
        vdev) warn "vdev $name is ${cap}% full while its pool reports ${pool_cap}% - ZFS spreads writes unevenly, and a nearly-full vdev fragments and slows resilvering" ;;
      esac
    done < <(zpool list -v 2>/dev/null | awk '
      NR == 1 { next }
      /^[^ \t]/ { if ($8 ~ /%$/) { pool_cap = $8 + 0; if (pool_cap > 85) print "pool", $1, pool_cap }; next }
      /^  [a-z]/ { cap = $8; gsub(/%/, "", cap); if (cap + 0 > 85 && cap + 0 > pool_cap + 1) print "vdev", $1, cap + 0, pool_cap }')
    unhealthy="$(timeout 30 zpool status -x 2>/dev/null)"
    echo "  $unhealthy"
    echo "$unhealthy" | grep -qi 'all pools are healthy' || warn "zpool status -x reports a problem - run 'zpool status -v' for the detail"
    for p in $(zpool list -H -o name 2>/dev/null); do
      pstat="$(timeout 30 zpool status "$p" 2>/dev/null)"
      phealth="$(zpool list -H -o health "$p" 2>/dev/null)"
      if [ "$phealth" != "ONLINE" ]; then
        # Losing a vdev loses the whole pool, so a degraded vdev is a
        # pool-wide risk even when the other vdevs are perfectly healthy.
        # Spelling out how much redundancy is left is the difference between
        # "there is a warning" and "one more failure and everything is gone".
        bad="$(echo "$pstat" | awk '/(FAULTED|DEGRADED|UNAVAIL|OFFLINE|REMOVED)/ && $1 !~ /^(state|status|action)/ {print $1"("$2")"}' | tr '\n' ' ')"
        warn "pool $p is $phealth - affected: $bad"
        # Per unhealthy vdev: its name, its direct members, and how many of
        # those are not ONLINE. Only direct members count, so a nested
        # replacing-N or spare-N group counts as one device.
        while read -r vdev members down; do
          [ -z "$vdev" ] && continue
          case "$vdev" in
            mirror*) left=$((members - 1 - down)) ;;
            raidz1*|draid1*) left=$((1 - down)) ;;
            raidz2*|draid2*) left=$((2 - down)) ;;
            raidz3*|draid3*) left=$((3 - down)) ;;
            *) continue ;;
          esac
          if [ "$left" -le 0 ]; then
            warn "vdev $vdev has $down of $members devices down and NO redundancy left: one more failure in it destroys the ENTIRE pool including its healthy vdevs. Replace the device; clearing the error only hides it."
          else
            warn "vdev $vdev has $down of $members devices down and can lose $left more before data is lost - replace promptly, redundancy is reduced."
          fi
        done < <(echo "$pstat" | awk '
          function emit() { if (vdev_state != "ONLINE") print vdev, members, down }
          $1 == "NAME" && $2 == "STATE" { in_config = 1; next }
          /^errors:/ { in_config = 0 }
          in_config && NF >= 2 {
            match($0, /^[\t ]*/); indent = RLENGTH
            if (vdev != "" && indent <= vdev_indent) { emit(); vdev = "" }
            if ($1 ~ /^(mirror|raidz|draid)/) { vdev = $1; vdev_indent = indent; vdev_state = $2; member_indent = 0; members = 0; down = 0; next }
            if (vdev == "") { next }
            if (member_indent == 0) { member_indent = indent }
            if (indent == member_indent) { members++; if ($2 != "ONLINE") { down++ } }
          }
          END { if (vdev != "") { emit() } }')
      fi
      scan="$(echo "$pstat" | grep -E '^\s+scan:' | sed 's/^\s*//')"
      echo "  $p: ${scan:-scan state unknown}"
      echo "$scan" | grep -qi 'none requested' && warn "pool $p has never been scrubbed - schedule a scrub to detect silent corruption early"
      # Columns 3-5 of a vdev line are READ/WRITE/CKSUM error counters.
      while read -r e; do
        [ -n "$e" ] && warn "pool $p: $e"
      done < <(echo "$pstat" | awk '/(ONLINE|DEGRADED|FAULTED|UNAVAIL|OFFLINE)/ && NF>=5 && $1!="state:" {e=$3+$4+$5; if (e>0) print $1" reports "$3" read, "$4" write, "$5" checksum errors"}')
    done
  fi
  echo "  -- filesystem usage --"
  df -h / /var/lib/vz 2>/dev/null | sed 's/^/  /'
  root_use="$(df --output=pcent / 2>/dev/null | tail -1 | tr -dc '0-9')"
  [ -n "$root_use" ] && [ "$root_use" -gt 85 ] && warn "root filesystem is ${root_use}% full"
fi

# --------------------------------------------------------------------------
if sec guests; then
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
fi

# --------------------------------------------------------------------------
if sec backup; then
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
fi

# --------------------------------------------------------------------------
if sec services; then
  echo "  -- failed units --"
  failed="$(systemctl --failed --no-legend 2>/dev/null)"
  if [ -n "$failed" ]; then
    echo "$failed" | sed 's/^/  /'
    warn "$(echo "$failed" | wc -l) failed systemd unit(s)"
  else
    note "none"
  fi
  echo "  -- core PVE services --"
  for s in pve-cluster corosync pvedaemon pveproxy pvestatd pve-firewall pvescheduler; do
    st="$(systemctl is-active "$s" 2>/dev/null)"
    printf '  %-16s %s\n' "$s" "$st"
    [ "$st" = "active" ] || warn "service $s is $st"
  done
fi

# --------------------------------------------------------------------------
if sec packages; then
  echo "  -- pending updates --"
  up="$(apt_upgradable)"
  n="$(echo "$up" | grep -c . )"
  echo "  $n package(s) upgradable"
  echo "$up" | grep -E 'pve-manager|proxmox-kernel|pve-qemu|libpve|corosync|zfs|ceph' | sed 's/^/  /' | head -15
  echo "  -- broken packages --"
  broken="$(dpkg -C 2>/dev/null)"
  if [ -n "$broken" ]; then echo "$broken" | sed 's/^/  /'; warn "dpkg reports packages in a broken state"; else note "dpkg -C: clean"; fi
  # "hi" is installed and on hold - deliberate, not broken.
  half="$(dpkg -l 2>/dev/null | awk 'NR>5 && $1 !~ /^[ih]i$/ && $1!="rc" {print "  "$1" "$2}' | head -10)"
  if [ -n "$half" ]; then
    echo "$half"
    warn "package(s) not fully installed (state is not 'ii') - fix with 'apt --fix-broken install' before any other upgrade"
  fi
  echo "  -- repositories --"
  suite="$(. /etc/os-release 2>/dev/null && echo "$VERSION_CODENAME")"
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*; do
    [ -f "$f" ] || continue
    case "$f" in
      *.dpkg-dist|*.dpkg-old|*.save|*.bak)
        warn "leftover file $f - apt ignores it, but it means a packaged repo change was never merged"
        continue ;;
    esac
    active="$(grep -vE '^\s*(#|$)' "$f" 2>/dev/null)"
    [ -z "$active" ] && continue
    if grep -qi '^Enabled: *no' "$f" 2>/dev/null; then note "$(basename "$f"): present but disabled"; continue; fi
    echo "  [$(basename "$f")]"
    echo "$active" | sed 's/^/    /'
    # Any known codename other than the running one is a leftover; a fixed list
    # of "old" names would flag the current suite on older majors.
    other="$(echo "$active" | tr ' /' '\n\n' | sed -E 's/-(updates|security|backports)$//' \
      | grep -xE 'buster|bullseye|bookworm|trixie|forky' | grep -vx "$suite" | sort -u | tr '\n' ' ')"
    if [ -n "$suite" ] && [ -n "$other" ]; then
      warn "$f points at suite ${other% } while this host runs $suite - a leftover from an earlier major upgrade; it can pull in wrong-version packages"
    fi
    echo "$active" | grep -q 'enterprise.proxmox.com' && note "$(basename "$f") uses the enterprise repo (needs a subscription; without one 'apt update' fails with 401)"
  done
fi

# --------------------------------------------------------------------------
if sec certs; then
  for c in /etc/pve/local/pve-ssl.pem /etc/pve/local/pveproxy-ssl.pem; do
    [ -f "$c" ] || continue
    end="$(openssl x509 -enddate -noout -in "$c" 2>/dev/null | cut -d= -f2)"
    subj="$(openssl x509 -subject -noout -in "$c" 2>/dev/null | sed 's/^subject= *//')"
    endep="$(date -d "$end" +%s 2>/dev/null)"; now="$(date +%s)"
    days=$(( (endep - now) / 86400 ))
    printf '  %-24s expires %s (%s days)\n' "$(basename "$c")" "$end" "$days"
    echo "      $subj"
    [ "$days" -lt 21 ] && warn "$(basename "$c") expires in $days days"
  done
fi

# --------------------------------------------------------------------------
if sec network; then
  # Guests each add fwbr/fwpr/fwln/veth/tap interfaces; on a busy host that is
  # hundreds of lines of noise that hides the handful of interfaces a human
  # actually configured, so only real uplinks and bridges are listed.
  echo "  -- uplinks, bonds, bridges, vlans --"
  ip -brief address 2>/dev/null | grep -vE '^(fw(br|pr|ln)|veth|tap)' | sed 's/^/  /'
  guest_ifs="$(ip -brief link 2>/dev/null | grep -cE '^(fw(br|pr|ln)|veth|tap)')"
  note "$guest_ifs guest-attached interfaces hidden (fwbr/fwpr/veth/tap)"
  echo "  -- bridge members --"
  for br in $(ip -brief link show type bridge 2>/dev/null | awk '{print $1}' | grep -vE '^fwbr'); do
    members="$(ls /sys/class/net/"$br"/brif 2>/dev/null | grep -vE '^(fwpr|veth|tap|fwln)' | tr '\n' ' ')"
    printf '  %-12s <- %s\n' "$br" "${members:-(only guest interfaces)}"
  done
  # An interface claimed by both a bond and a bridge is a latent trap: it works
  # for as long as nobody reloads the config, and then `ifreload -a` enacts the
  # stanza that was never active and the uplink disappears. Worth finding before
  # someone applies an unrelated network change.
  echo "  -- interface definition conflicts --"
  conflicts="$(cat /etc/network/interfaces /etc/network/interfaces.d/* 2>/dev/null | awk '
    /^[[:space:]]*iface[[:space:]]/ { cur=$2 }
    /^[[:space:]]*bond-master[[:space:]]/ { master[cur]=$2 }
    /^[[:space:]]*bond-slaves[[:space:]]/ { for(i=2;i<=NF;i++) slave[$i]=1 }
    /^[[:space:]]*bridge-ports[[:space:]]/ { for(i=2;i<=NF;i++) if ($i != "none") port[$i]=1 }
    END {
      for (i in master) if (i in port)
        print i" is declared with bond-master "master[i]" while also being a bridge-port"
      for (i in slave) if (i in port)
        print i" is listed as a bond-slave and as a bridge-port"
    }')"
  if [ -n "$conflicts" ]; then
    echo "$conflicts" | while read -r c; do
      [ -n "$c" ] && warn "network config conflict: $c. It survives only while the config is not reloaded - 'ifreload -a' or a reboot may enact the inactive stanza and take the uplink down. Resolve the definition before applying any network change, and always dry-run with 'ifreload -a -n' first."
    done
  else
    note "no conflicting bond/bridge claims found"
  fi

  echo "  -- pending network changes --"
  if [ -f /etc/network/interfaces.new ]; then
    warn "/etc/network/interfaces.new exists: a network change is staged but not applied (apply it in the GUI, or reboot)"
    diff -u /etc/network/interfaces /etc/network/interfaces.new 2>/dev/null | head -30 | sed 's/^/  /'
  else
    note "none staged"
  fi
  echo "  -- time sync --"
  have chronyc && timeout 10 chronyc tracking 2>/dev/null | grep -E 'Reference ID|System time|Leap' | sed 's/^/  /'
  have timedatectl && echo "  NTP synchronized: $(timedatectl show -p NTPSynchronized --value 2>/dev/null)"
fi

# --------------------------------------------------------------------------
# Disk health runs by default: it costs about five seconds, and on a hypervisor
# the disks are the thing whose failure is least recoverable. Holding it behind
# a flag meant the wear and temperature problems on this host went unmentioned
# in the very reports that were meant to surface them.
if sec smart; then
  if have smartctl; then
    # zd* are ZFS zvols (guest disks), not physical media - asking them for
    # SMART data is meaningless, so they are skipped rather than reported
    # as unreadable.
    for d in $(lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2=="disk" && $1 !~ /^zd/{print $1}'); do
      info="$(timeout 30 smartctl -HiA "/dev/$d" 2>/dev/null)"
      health="$(echo "$info" | grep -iE 'overall-health|SMART Health' | sed 's/^.*: *//' | tr -d ' \r')"
      model="$(echo "$info" | awk -F': *' '/Device Model|Model Number/{print $2; exit}')"
      hours="$(echo "$info" | awk '/Power_On_Hours|Power On Hours/{gsub(/,/,"",$NF); print $NF; exit}')"
      used="$(echo "$info" | awk -F': *' '/Percentage Used/{gsub(/[^0-9]/,"",$2); print $2; exit}')"
      realloc="$(echo "$info" | awk '/Reallocated_Sector_Ct/{print $NF; exit}')"
      pending="$(echo "$info" | awk '/Current_Pending_Sector/{print $NF; exit}')"
      # SATA reports temperature as attribute 194, NVMe as a "Temperature:"
      # line. Heat is the single biggest accelerator of drive failure, and it
      # is invisible in every other check here, so it is worth both forms.
      temp="$(echo "$info" | awk '/Temperature_Celsius|Airflow_Temperature/{print $10; exit}')"
      [ -z "$temp" ] && temp="$(echo "$info" | awk -F': *' '/^Temperature:/{gsub(/[^0-9]/,"",$2); print $2; exit}')"
      # Vendors append "(Min/Max 21/67)" in wildly varying shapes, so pick the
      # max out explicitly rather than trusting the last field.
      tmax="$(echo "$info" | grep -m1 -oE 'Min/Max +[0-9]+/[0-9]+' | grep -oE '[0-9]+$')"
      wearsata="$(echo "$info" | awk '/Media_Wearout_Indicator|Wear_Leveling_Count|SSD_Life_Left/{print $2"(val "$4")"; exit}')"

      # No health line at all means SMART could not be read (USB bridge, RAID
      # HBA, virtual device). That is a gap in visibility, not a failing
      # disk, so it is reported as a note rather than raised as an alarm.
      if [ -z "$health" ]; then
        note "$d (${model:-unknown model}): SMART not readable - controller may not pass it through (try: smartctl -d sat -a /dev/$d)"
        continue
      fi
      printf '  %-8s %-26s health=%-8s hours=%-8s%s%s%s%s\n' \
        "$d" "${model:-?}" "${health:-?}" "${hours:-?}" \
        "${temp:+ temp=${temp}C}" "${used:+ used=${used}%}" \
        "${realloc:+ realloc=$realloc}" "${pending:+ pending=$pending}"

      # Spinning disks are specified to roughly 55-60 C; sustained operation
      # above that measurably shortens their life, and a resilver or scrub
      # pushes every disk at once for days.
      if [ -n "$temp" ] && [ "$temp" -ge 55 ] 2>/dev/null; then
        if [ "$temp" -ge 60 ]; then
          warn "disk /dev/$d runs at ${temp}C${tmax:+ (lifetime max ${tmax}C)} - above the ~55-60C the manufacturer specifies. Heat is the strongest predictor of drive failure, and a resilver keeps every disk at full load for days. Improve airflow before starting one."
        else
          note "$d is warm at ${temp}C - watch it; sustained operation above ~55C shortens disk life"
        fi
      fi

      echo "$health" | grep -qiE 'passed|ok' || warn "disk /dev/$d (${model:-unknown}) SMART self-assessment is '$health'"
      # "Percentage Used" counts down the manufacturer's rated endurance. At
      # 100% the drive is past its write-endurance budget even though SMART
      # still says PASSED, so it deserves a warning of its own.
      if [ -n "$used" ] && [ "$used" -ge 80 ] 2>/dev/null; then
        warn "SSD /dev/$d (${model:-unknown}) has used ${used}% of its rated write endurance - plan replacement; at 100% the manufacturer no longer guarantees data retention even while SMART reports PASSED"
      fi
      [ -n "$realloc" ] && [ "$realloc" -gt 0 ] 2>/dev/null && warn "disk /dev/$d has $realloc reallocated sector(s) - failing media"
      [ -n "$pending" ] && [ "$pending" -gt 0 ] 2>/dev/null && warn "disk /dev/$d has $pending sector(s) pending reallocation - unreadable data, check the pool it belongs to"
      [ -n "$wearsata" ] && note "$d wear indicator: $wearsata"
    done
  else
    note "smartctl not installed (package: smartmontools)"
  fi
fi

# --------------------------------------------------------------------------
if [ "$FULL" = 1 ] || [ "$ONLY" = "logs" ]; then
  if sec logs; then
    echo "  -- errors in the last 24h, most frequent first --"
    journalctl --since '24 hours ago' -p err --no-pager 2>/dev/null \
      | sed -E 's/^[A-Z][a-z]{2} +[0-9]+ [0-9:]+ [^ ]+ //; s/[0-9]{4,}/N/g' \
      | sort | uniq -c | sort -rn | head -20 | sed 's/^/  /'
  fi
fi

# --------------------------------------------------------------------------
if [ "$CLUSTER" = 1 ] && [ -e /etc/pve/corosync.conf ]; then
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
fi

printf '\n===== SUMMARY =====\n'
if [ "$WARN_COUNT" = 0 ]; then
  echo "  no warnings raised"
else
  echo "  $WARN_COUNT warning(s) - see the !! lines above"
fi
echo "  scope: node=$NODE full=$FULL cluster=$CLUSTER${ONLY:+ section=$ONLY}"
exit 0
