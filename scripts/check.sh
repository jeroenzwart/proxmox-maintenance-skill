#!/usr/bin/env bash
# Read-only health snapshot of a Proxmox host: PVE, PBS, PDM, or a mix.
#
# Every command here only observes: nothing is started, stopped, installed or
# written. That is deliberate - this runs first, before any diagnosis, so the
# conclusions rest on what the machine actually reports rather than on
# assumptions about how it was set up.
#
# Usage: check.sh [--full] [--cluster] [--diff] [--json] [--product P] [--section NAME] [--products]
#   --full          also read recent journal errors (slower)
#   --diff          after the summary, compare with the previous full run
#   --json          print only one JSON document: host, products, warnings, notes
#   --cluster       PVE: repeat the core checks on the other nodes via SSH
#   --product P     only the sections of one product: pve pbs pdm
#   --section NAME  run only one section (host-level or product)
#   --products      print the detected products and exit
#
# Host-level sections: identity services packages certs network zfs disk smart notifications security logs
# Only on request (--section): update
# PVE: cluster storage guests backup coverage snapshots replication ceph
# PBS: datastores gc jobs tasks remotes tape
# PDM: remotes subscriptions

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HOST_SECTIONS="identity services packages certs network zfs disk smart notifications security logs update"
PVE_SECTIONS="cluster storage guests backup coverage snapshots replication ceph"
PBS_SECTIONS="datastores gc jobs tasks remotes tape"
PDM_SECTIONS="remotes subscriptions"

FULL=0
CLUSTER=0
ONLY=""
ONLY_PRODUCT=""
LIST_PRODUCTS=0
DIFF=0
JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --full) FULL=1 ;;
    --cluster) CLUSTER=1 ;;
    --diff) DIFF=1 ;;
    --json) JSON=1 ;;
    --product) ONLY_PRODUCT="${2:-}"; shift ;;
    --product=*) ONLY_PRODUCT="${1#*=}" ;;
    --section) ONLY="${2:-}"; shift ;;
    --section=*) ONLY="${1#*=}" ;;
    --products) LIST_PRODUCTS=1 ;;
    -h|--help) sed -n '2,/^$/{/^$/d;p}' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

RECORD="$(mktemp)"
trap 'rm -f "$RECORD"' EXIT

# shellcheck source=checks/common.sh
. "$SCRIPT_DIR/checks/common.sh"

if [ "$LIST_PRODUCTS" = 1 ]; then
  echo "$PRODUCTS"
  exit 0
fi

product_sections() {
  case "$1" in
    pve) echo "$PVE_SECTIONS" ;;
    pbs) echo "$PBS_SECTIONS" ;;
    pdm) echo "$PDM_SECTIONS" ;;
  esac
}

contains() {
  case " $1 " in
    *" $2 "*) return 0 ;;
  esac

  return 1
}

# A mistyped section would run nothing and then report "no warnings raised",
# which reads as a clean bill of health; so would a section of a product that
# is not on this host.
validate_section() {
  local owners="" product
  [ -z "$ONLY" ] && return 0
  contains "$HOST_SECTIONS" "$ONLY" && return 0
  for product in pve pbs pdm; do
    contains "$(product_sections "$product")" "$ONLY" && owners="$owners $product"
  done
  if [ -z "$owners" ]; then
    echo "unknown section: $ONLY" >&2
    exit 2
  fi
  for product in $owners; do
    contains "$PRODUCTS" "$product" && return 0
  done
  echo "section $ONLY belongs to${owners}, which is not installed on this host" >&2
  exit 2
}

validate_product() {
  [ -z "$ONLY_PRODUCT" ] && return 0
  case "$ONLY_PRODUCT" in
    pve|pbs|pdm) ;;
    *) echo "unknown product: $ONLY_PRODUCT" >&2; exit 2 ;;
  esac
  contains "$PRODUCTS" "$ONLY_PRODUCT" && return 0
  echo "product $ONLY_PRODUCT is not installed on this host" >&2
  exit 2
}

run_product() {
  local product="$1" section
  [ -n "$ONLY_PRODUCT" ] && [ "$ONLY_PRODUCT" != "$product" ] && return 0
  [ -f "$SCRIPT_DIR/checks/$product.sh" ] || return 0
  # shellcheck disable=SC1090
  . "$SCRIPT_DIR/checks/$product.sh"
  for section in $(product_sections "$product"); do
    "${product}_${section}"
  done
}

print_summary() {
  local count
  count="$(warn_count)"
  printf '\n===== SUMMARY =====\n'
  if [ "$count" = 0 ]; then
    echo "  no warnings raised"
  else
    echo "  $count warning(s) - see the !! lines above"
  fi
  echo "  scope: node=$NODE products=${PRODUCTS:-none} full=$FULL cluster=$CLUSTER${ONLY_PRODUCT:+ product=$ONLY_PRODUCT}${ONLY:+ section=$ONLY}"
}

validate_section
validate_product
# The human report still runs in full, so the record is the same either way;
# stdout carries nothing but the document.
if [ "$JSON" = 1 ]; then
  exec 3>&1 1>/dev/null
fi
# A partial run compared with a full one would list everything it skipped as gone.
if [ "$DIFF" = 1 ] && { [ -n "$ONLY" ] || [ -n "$ONLY_PRODUCT" ]; }; then
  echo "--diff compares full runs; drop --section and --product" >&2
  exit 2
fi

host_identity
host_services
host_packages
host_certs
host_network
host_zfs
host_disk
host_smart
host_notifications
host_security
for product in $PRODUCTS; do
  run_product "$product"
done
if [ "$FULL" = 1 ] || [ "$ONLY" = "logs" ]; then
  host_logs
fi
# Update readiness repeats checks from other sections, so it is not part of
# the default sweep; run it before an update.
[ "$ONLY" = "update" ] && host_update
# pve.sh is only sourced when the PVE sections ran.
if [ "$CLUSTER" = 1 ] && declare -F pve_cluster_sweep >/dev/null; then
  pve_cluster_sweep
fi

print_summary
# Only full runs are saved, so the previous run is always comparable.
if [ -z "$ONLY" ] && [ -z "$ONLY_PRODUCT" ]; then
  if [ "$DIFF" = 1 ]; then
    printf '\n===== DIFF WITH THE PREVIOUS RUN =====\n'
    changes="$(python3 "$SCRIPT_DIR/checks/history.py" diff "$RECORD")"
    if [ -n "$changes" ]; then
      echo "$changes" | sed 's/^/  /'
    else
      echo "  -- no warning appeared or disappeared, no metric moved"
    fi
  fi
  python3 "$SCRIPT_DIR/checks/history.py" save "$RECORD" | sed 's/^/  /'
fi
if [ "$JSON" = 1 ]; then
  python3 - "$RECORD" "$NODE" "$PRODUCTS" >&3 <<'PY'
import json, sys
record, host, products = sys.argv[1:4]
found = {"WARN": [], "NOTE": []}
with open(record, encoding="utf-8", errors="replace") as lines:
    for line in lines:
        kind, _, rest = line.rstrip("\n").partition("\t")
        section, _, message = rest.partition("\t")
        if kind in found:
            found[kind].append({"section": section, "message": message})
print(json.dumps({"host": host, "products": products.split(), "warnings": found["WARN"], "notes": found["NOTE"]}, indent=2))
PY
fi
exit 0
