# Shared helpers and host-level sections for check.sh. Sourced, not run.
#
# Host-level sections look at the Debian host underneath any Proxmox product:
# packages, services, certificates, network, ZFS, disks. They run once per
# host, whichever products are installed.

WARN_COUNT=0
NODE="$(hostname)"

# Kernels and initrds land in /boot; an update that runs out of room there
# leaves a half-installed kernel behind.
BOOT_MIN_FREE_MB=200

CURRENT_SECTION=""
# Every finding and metric also goes to the run record, a file rather than a
# variable so that one raised inside a subshell is kept too. check.sh creates it.
RECORD="${RECORD:-/dev/null}"

sec() {
  [ -n "$ONLY" ] && [ "$ONLY" != "$1" ] && return 1
  CURRENT_SECTION="$1"
  printf '\n===== %s =====\n' "$(echo "$1" | tr '[:lower:]' '[:upper:]')"

  return 0
}
record() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$RECORD"; }
warn() { WARN_COUNT=$((WARN_COUNT + 1)); printf '  !! %s\n' "$*"; record WARN "$CURRENT_SECTION" "$*"; }
note() { printf '  -- %s\n' "$*"; record NOTE "$CURRENT_SECTION" "$*"; }
# A value worth comparing between runs (check.sh --diff); prints nothing.
metric() { record METRIC "$1" "$2"; }
have() { command -v "$1" >/dev/null 2>&1; }
# Map WARN/NOTE lines from the report helpers onto warn/note. Feed it with
# `< <(...)`, not a pipe: in a piped subshell the warning count is lost.
report_lines() {
  local kind message
  while read -r kind message; do
    case "$kind" in
      WARN) warn "$message" ;;
      NOTE) note "$message" ;;
    esac
  done
}

# --- products ---------------------------------------------------------------
# The server package decides, not a client tool: every PVE host also carries
# proxmox-backup-client, which says nothing about running a backup server.
product_package() {
  case "$1" in
    pve) echo pve-manager ;;
    pbs) echo proxmox-backup-server ;;
    pdm) echo proxmox-datacenter-manager ;;
  esac
}
product_installed() {
  [ "$(dpkg-query -W -f '${Status}' "$(product_package "$1")" 2>/dev/null)" = "install ok installed" ]
}
product_version() {
  dpkg-query -W -f '${Version}' "$(product_package "$1")" 2>/dev/null
}
product_port() {
  case "$1" in
    pve) echo 8006 ;;
    pbs) echo 8007 ;;
    pdm) echo 8443 ;;
  esac
}
product_units() {
  local product
  for product in $PRODUCTS; do
    case "$product" in
      pve) echo pve-cluster corosync pvedaemon pveproxy pvestatd pve-firewall pvescheduler ;;
      pbs) echo proxmox-backup proxmox-backup-proxy ;;
      pdm) echo proxmox-datacenter-api proxmox-datacenter-privileged-api proxmox-datacenter-manager-daily-update.timer ;;
    esac
  done
}
# The packages whose updates carry real consequences, for the products present.
product_update_pattern() {
  local pattern="proxmox-kernel|zfs" product
  for product in $PRODUCTS; do
    case "$product" in
      pve) pattern="$pattern|pve-manager|pve-qemu|libpve|corosync|ceph" ;;
      pbs) pattern="$pattern|proxmox-backup" ;;
      pdm) pattern="$pattern|proxmox-datacenter-manager" ;;
    esac
  done
  echo "$pattern"
}

PRODUCTS=""
for product in pve pbs pdm; do
  product_installed "$product" && PRODUCTS="${PRODUCTS:+$PRODUCTS }$product"
done

# A container has no disks or kernel of its own, so SMART, ZFS and kernel
# checks there report the host's state or nothing at all.
IN_CONTAINER=0
have systemd-detect-virt && systemd-detect-virt --container >/dev/null 2>&1 && IN_CONTAINER=1

# Days until the certificate served on HOST:PORT expires; empty when nothing
# answers. Reading the served certificate avoids guessing each product's path.
cert_expiry_days() {
  local end
  end="$(echo | timeout 10 openssl s_client -connect "$1" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
  [ -n "$end" ] || return 0
  echo $(( ($(date -d "$end" +%s) - $(date +%s)) / 86400 ))
}

# --- memoised readers -------------------------------------------------------
_apt=""; _apt_done=0
apt_upgradable() {
  [ "$_apt_done" = 1 ] || { _apt="$(timeout 60 apt list --upgradable 2>/dev/null | tail -n +2)"; _apt_done=1; }
  printf '%s\n' "$_apt"
}

host_identity() {
  sec identity || return 0
  echo "node        : $NODE"
  echo "date        : $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "uptime      :$(uptime -p 2>/dev/null | sed 's/^up//')"
  for product in $PRODUCTS; do
    printf '%-12s: %s %s\n' "$product" "$(product_package "$product")" "$(product_version "$product")"
  done
  [ -z "$PRODUCTS" ] && warn "no Proxmox product found (pve-manager, proxmox-backup-server, proxmox-datacenter-manager)"
  echo "debian      : $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
  if [ "$IN_CONTAINER" = 1 ]; then
    note "running in a container: kernel and reboot state belong to the host, skipped"
  else
    kernel_status
  fi
  if have pvesubscription; then
    sub="$(timeout 15 pvesubscription get 2>/dev/null | awk -F': *' '/^status/{print $2}')"
    echo "subscription: ${sub:-unknown}"
  fi
}

kernel_status() {
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
}

host_services() {
  sec services || return 0
  echo "  -- failed units --"
  failed="$(systemctl --failed --no-legend 2>/dev/null)"
  if [ -n "$failed" ]; then
    echo "$failed" | sed 's/^/  /'
    warn "$(echo "$failed" | wc -l) failed systemd unit(s)"
  else
    note "none"
  fi
  echo "  -- core product services --"
  for s in $(product_units); do
    st="$(systemctl is-active "$s" 2>/dev/null)"
    printf '  %-44s %s\n' "$s" "$st"
    [ "$st" = "active" ] || warn "service $s is $st"
  done
}

host_packages() {
  sec packages || return 0
  echo "  -- pending updates --"
  up="$(apt_upgradable)"
  n="$(echo "$up" | grep -c . )"
  echo "  $n package(s) upgradable"
  echo "$up" | grep -E "$(product_update_pattern)" | sed 's/^/  /' | head -15
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
}

host_certs() {
  sec certs || return 0
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
  for product in $PRODUCTS; do
    port="$(product_port "$product")"
    days="$(cert_expiry_days "localhost:$port")"
    if [ -z "$days" ]; then
      warn "$product web interface on port $port did not answer with a certificate"
      continue
    fi
    printf '  %-24s served on %s, expires in %s days\n' "$product" "$port" "$days"
    [ "$days" -lt 21 ] && warn "$product certificate on port $port expires in $days days"
  done
}

host_network() {
  sec network || return 0
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
  echo "  -- interface definition conflicts --"
  if [ "$IN_CONTAINER" = 1 ]; then
    note "running in a container: the host owns the network definition, skipped"
  else
    network_conflicts
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
}

network_conflicts() {
  # An interface claimed by both a bond and a bridge is a latent trap: it works
  # for as long as nobody reloads the config, and then `ifreload -a` enacts the
  # stanza that was never active and the uplink disappears. Worth finding before
  # someone applies an unrelated network change.
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
    while read -r c; do
      [ -n "$c" ] && warn "network config conflict: $c. It survives only while the config is not reloaded - 'ifreload -a' or a reboot may enact the inactive stanza and take the uplink down. Resolve the definition before applying any network change, and always dry-run with 'ifreload -a -n' first."
    done <<< "$conflicts"
  else
    note "no conflicting bond/bridge claims found"
  fi
}

host_zfs() {
  sec zfs || return 0
  if [ "$IN_CONTAINER" = 1 ]; then
    note "running in a container: pools belong to the host, skipped"

    return 0
  fi
  if have zpool; then
    echo "  -- zfs pools --"
    zpool list 2>/dev/null | sed 's/^/  /'
    while read -r name cap; do
      metric "zfs.$name.cap" "${cap%\%}"
    done < <(zpool list -H -o name,cap 2>/dev/null)
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
}

host_disk() {
  sec disk || return 0
  echo "  -- filesystem usage --"
  df -h / /var/lib/vz 2>/dev/null | sed 's/^/  /'
  root_use="$(df --output=pcent / 2>/dev/null | tail -1 | tr -dc '0-9')"
  [ -n "$root_use" ] && metric disk.root.use "$root_use"
  [ -n "$root_use" ] && [ "$root_use" -gt 85 ] && warn "root filesystem is ${root_use}% full"
}

host_smart() {
  sec smart || return 0
  if [ "$IN_CONTAINER" = 1 ]; then
    note "running in a container: disks belong to the host, skipped"

    return 0
  fi
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
      # By serial: /dev names can swap between boots, which would read as movement.
      serial="$(echo "$info" | awk -F': *' '/Serial Number/{print $2; exit}' | tr -d ' ')"
      [ -n "$realloc" ] && metric "smart.${serial:-$d}.realloc" "$realloc"
      [ -n "$pending" ] && metric "smart.${serial:-$d}.pending" "$pending"
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
}

host_logs() {
  sec logs || return 0
  echo "  -- errors in the last 24h, most frequent first --"
  journalctl --since '24 hours ago' -p err --no-pager 2>/dev/null \
    | sed -E 's/^[A-Z][a-z]{2} +[0-9]+ [0-9:]+ [^ ]+ //; s/[0-9]{4,}/N/g' \
    | sort | uniq -c | sort -rn | head -20 | sed 's/^/  /'
}

host_update() {
  local count free checker quorate
  sec update || return 0
  if [ "$IN_CONTAINER" = 1 ]; then
    note "running in a container: kernel and reboot state belong to the host, skipped"
  else
    kernel_status
  fi
  count="$(apt_upgradable | grep -c .)"
  echo "  $count package(s) upgradable (apt list --upgradable; run 'apt update' first for a fresh list)"
  free="$(df -m --output=avail /boot 2>/dev/null | tail -1 | tr -dc '0-9')"
  if [ -n "$free" ]; then
    echo "  /boot: ${free} MB free"
    [ "$free" -lt "$BOOT_MIN_FREE_MB" ] && warn "/boot has only ${free} MB free (below ${BOOT_MIN_FREE_MB} MB) - a kernel update may fail halfway; remove old kernels first"
  fi
  if contains "$PRODUCTS" pve; then
    # shellcheck source=pve.sh
    . "$SCRIPT_DIR/checks/pve.sh"
    if [ -e /etc/pve/corosync.conf ]; then
      quorate="$(pvecm_status | awk -F': *' '/^Quorate/{print $2; exit}' | tr -d ' \r')"
      if [ "$quorate" = "Yes" ]; then
        note "cluster is quorate"
      else
        warn "cluster quorum is '${quorate:-unknown}' - do not update until the cluster is quorate"
      fi
    fi
    echo "  -- backup coverage --"
    pve_coverage_report
  fi
  for checker in pve8to9 pve9to10 pbs3to4 pbs4to5; do
    have "$checker" && note "$checker is installed: before a major upgrade run '$checker --full' and resolve every FAIL and WARN"
  done
}

# Users with an e-mail address, as "<userid> <email>" lines. PVE keeps users on
# one colon-separated line each (email is field 7); PBS uses section blocks.
user_emails() {
  case "$1" in
    pve) awk -F: '$1 == "user" && $7 != "" {print $2, $7}' /etc/pve/user.cfg 2>/dev/null ;;
    pbs) awk '/^user:/ {user = $2} /^[[:space:]]+email[[:space:]]/ && user != "" {print user, $2}' /etc/proxmox-backup/user.cfg 2>/dev/null ;;
  esac
}

# A failed backup that notifies nobody is found only when someone needs the
# backup. PBS user.cfg handling is built from the docs, not yet seen on a host.
host_notifications() {
  local product config
  sec notifications || return 0
  for product in $PRODUCTS; do
    case "$product" in
      pve) config=/etc/pve/notifications.cfg ;;
      pbs) config=/etc/proxmox-backup/notifications.cfg ;;
      *) continue ;;
    esac
    echo "  -- $product: $config --"
    if [ -f "$config" ]; then
      awk '/^[a-z-]+: / {kind = $1; name = $2} /^[[:space:]]+(target|disable)[[:space:]]/ {print "    " kind " " name ": " $1 " " $2}' "$config"
    else
      note "$config does not exist - the built-in default (mail to root@pam) applies"
    fi
    report_lines < <({ cat "$config" 2>/dev/null; echo "### users"; user_emails "$product"; } \
      | python3 "$SCRIPT_DIR/checks/pve_report.py" notifications)
  done
}

# Notes unless stated: these are choices an admin may have made on purpose.
# Only what the host itself shows is reported - whether a port is reachable
# from outside depends on the network in front of it.
host_security() {
  local tfa=/etc/pve/priv/tfa.cfg
  sec security || return 0
  report_lines < <({
      echo "### tfa"
      if ! contains "$PRODUCTS" pve; then
        echo SKIP
      elif [ -r "$tfa" ]; then
        # tfa.cfg has no trailing newline; without one the next header joins it.
        cat "$tfa"; echo
      else
        echo UNREADABLE
      fi
      echo "### sshd"
      have sshd && sshd -T 2>/dev/null | grep -iE '^(permitrootlogin|passwordauthentication) '
      if contains "$PRODUCTS" pve; then
        echo "### firewall"
        cat /etc/pve/firewall/cluster.fw 2>/dev/null; echo
      fi
    } | python3 "$SCRIPT_DIR/checks/pve_report.py" security)
}
