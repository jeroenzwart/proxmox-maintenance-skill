#!/usr/bin/env bash
# Read-only health snapshot of a Proxmox host: PVE, PBS, PDM, or a mix.
#
# Every command here only observes: nothing is started, stopped, installed or
# written. That is deliberate - this runs first, before any diagnosis, so the
# conclusions rest on what the machine actually reports rather than on
# assumptions about how it was set up.
#
# Usage: check.sh [--full] [--cluster] [--product P] [--section NAME] [--products]
#   --full          also read recent journal errors (slower)
#   --cluster       PVE: repeat the core checks on the other nodes via SSH
#   --product P     only the sections of one product: pve pbs pdm
#   --section NAME  run only one section (host-level or product)
#   --products      print the detected products and exit
#
# Host-level sections: identity services packages certs network zfs disk smart logs
# PVE: cluster storage guests backup
# PBS: datastores gc jobs tasks remotes tape
# PDM: remotes subscriptions

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HOST_SECTIONS="identity services packages certs network zfs disk smart logs"
PVE_SECTIONS="cluster storage guests backup"
PBS_SECTIONS="datastores gc jobs tasks remotes tape"
PDM_SECTIONS="remotes subscriptions"

FULL=0
CLUSTER=0
ONLY=""
ONLY_PRODUCT=""
LIST_PRODUCTS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --full) FULL=1 ;;
    --cluster) CLUSTER=1 ;;
    --product) ONLY_PRODUCT="${2:-}"; shift ;;
    --product=*) ONLY_PRODUCT="${1#*=}" ;;
    --section) ONLY="${2:-}"; shift ;;
    --section=*) ONLY="${1#*=}" ;;
    --products) LIST_PRODUCTS=1 ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

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
  printf '\n===== SUMMARY =====\n'
  if [ "$WARN_COUNT" = 0 ]; then
    echo "  no warnings raised"
  else
    echo "  $WARN_COUNT warning(s) - see the !! lines above"
  fi
  echo "  scope: node=$NODE products=${PRODUCTS:-none} full=$FULL cluster=$CLUSTER${ONLY_PRODUCT:+ product=$ONLY_PRODUCT}${ONLY:+ section=$ONLY}"
}

validate_section
validate_product

host_identity
host_services
host_packages
host_certs
host_network
host_zfs
host_disk
host_smart
for product in $PRODUCTS; do
  run_product "$product"
done
if [ "$FULL" = 1 ] || [ "$ONLY" = "logs" ]; then
  host_logs
fi
# pve.sh is only sourced when the PVE sections ran.
if [ "$CLUSTER" = 1 ] && declare -F pve_cluster_sweep >/dev/null; then
  pve_cluster_sweep
fi

print_summary
exit 0
