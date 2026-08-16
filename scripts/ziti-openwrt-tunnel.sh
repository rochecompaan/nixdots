#!/usr/bin/env bash
set -euo pipefail

# Operator tool for the ziti-edge-tunnel OpenWRT package: install or update
# the package on the router, and enroll the router identity against the Ziti
# controller. See docs/ziti-edge-tunnel-openwrt.md.
#
# The enrollment JWT only ever exists in a temporary directory with 0700
# permissions and is deleted when this script exits. It is never written to
# this repository. The ziti login session must be created interactively
# before running `enroll`; this script never passes passwords.

CONTROLLER=${ZITI_CONTROLLER:-ctrl.compaan.cloud:443}
ROUTER=${ROUTER:-root@192.168.1.1}
ENROLL_TIMEOUT=${ZITI_ENROLL_TIMEOUT:-30}

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(dirname "$SCRIPT_DIR")

cleanup_paths=()
cleanup() {
  if ((${#cleanup_paths[@]} > 0)); then
    rm -rf -- "${cleanup_paths[@]}"
  fi
}
trap cleanup EXIT

usage() {
  cat <<USAGE
Usage: $0 <command> [options]

Commands:
  install [--ipk <path>] [--router <user@host>]
      Build (or use --ipk) and install the package on the router.
      The service stays disabled until \`enroll\` runs.

  update [--ipk <path>] [--router <user@host>]
      Build (or use --ipk) and upgrade the package in place.
      Restarts the tunnel only if it is currently running.

  enroll --identity <name> [--attrs <csv>] [--router <user@host>]
      Create the controller identity, transfer the enrollment JWT
      securely, enable and start the service, and verify enrollment.
      Requires an interactive login first:
        ziti edge login ${CONTROLLER} -u <username>

Defaults:
  --router  ${ROUTER}
  controller ${CONTROLLER} (override with ZITI_CONTROLLER)
USAGE
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 2
  }
}

ipk_path=
router=$ROUTER

parse_common() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --ipk)
        [[ $# -ge 2 ]] || die "--ipk requires a value"
        ipk_path=$2
        shift 2
        ;;
      --router)
        [[ $# -ge 2 ]] || die "--router requires a value"
        router=$2
        shift 2
        ;;
      *)
        usage >&2
        exit 2
        ;;
    esac
  done
}

resolve_ipk() {
  if [[ -n $ipk_path ]]; then
    [[ -f $ipk_path ]] || die "ipk not found: $ipk_path"
    return 0
  fi
  require_cmd nix
  (cd "$REPO_ROOT" && nix build .#ziti-edge-tunnel-openwrt)
  local found
  mapfile -t found < <(printf '%s\n' "$REPO_ROOT"/result/ziti-edge-tunnel_*.ipk)
  [[ ${#found[@]} -eq 1 && -f ${found[0]} ]] ||
    die "expected exactly one built ipk, found ${#found[@]}"
  ipk_path=${found[0]}
}

copy_and_install() {
  require_cmd ssh
  require_cmd scp
  local base
  base=$(basename -- "$ipk_path")
  # Install the exact file: stale packages in /tmp plus a glob match make
  # opkg report the installed release as up to date without upgrading.
  ssh "$router" 'rm -f /tmp/ziti-edge-tunnel_*.ipk'
  scp "$ipk_path" "$router:/tmp/"
  ssh "$router" "opkg update && opkg install '/tmp/$base' && rm -f '/tmp/$base'"
}

cmd_install() {
  parse_common "$@"
  resolve_ipk
  copy_and_install
  ssh "$router" 'ziti-edge-tunnel version'
  printf 'installed on %s; service stays disabled until: %s enroll --identity <name>\n' \
    "$router" "$0"
}

cmd_update() {
  parse_common "$@"
  resolve_ipk
  copy_and_install
  # The package ships no postinst, so a running tunnel keeps the old
  # binary until restarted.
  if ssh "$router" '/etc/init.d/ziti-edge-tunnel running'; then
    ssh "$router" '/etc/init.d/ziti-edge-tunnel restart'
    ssh "$router" '/etc/init.d/ziti-edge-tunnel running' ||
      die "tunnel did not come back after restart; check: ssh $router 'logread -e ziti-edge-tunnel'"
  else
    printf 'tunnel not running on %s; leaving it stopped\n' "$router"
  fi
  ssh "$router" 'ziti-edge-tunnel version'
}

cmd_enroll() {
  local identity= attrs=
  while [[ $# -gt 0 ]]; do
    case $1 in
      --identity)
        [[ $# -ge 2 ]] || die "--identity requires a value"
        identity=$2
        shift 2
        ;;
      --attrs)
        [[ $# -ge 2 ]] || die "--attrs requires a value"
        attrs=$2
        shift 2
        ;;
      --router)
        [[ $# -ge 2 ]] || die "--router requires a value"
        router=$2
        shift 2
        ;;
      *)
        usage >&2
        exit 2
        ;;
    esac
  done
  [[ -n $identity ]] || die "enroll requires --identity <name>"

  require_cmd ziti
  require_cmd jq
  require_cmd ssh

  if ! ziti edge list identities 'limit 1' -j >/dev/null 2>&1; then
    die "not logged in; run: ziti edge login $CONTROLLER -u <username>"
  fi

  if ziti edge list identities "name = \"$identity\"" -j 2>/dev/null |
    jq -e '.data | length > 0' >/dev/null; then
    die "identity '$identity' already exists; recreating it invalidates the old enrollment. Delete it deliberately first: ziti edge delete identity \"$identity\""
  fi

  local tmp jwt
  tmp=$(mktemp -d)
  cleanup_paths+=("$tmp")
  chmod 0700 "$tmp"
  jwt=$tmp/enroll.jwt

  local create_args=(edge create identity "$identity" -o "$jwt")
  [[ -n $attrs ]] && create_args+=(--role-attributes "$attrs")
  ziti "${create_args[@]}"
  [[ -s $jwt ]] || die 'controller produced no JWT'

  ssh "$router" 'umask 077; cat > /etc/openziti/enroll.jwt' <"$jwt"
  rm -rf -- "$tmp"
  cleanup_paths=()

  ssh "$router" "uci set ziti-edge-tunnel.main.enabled='1'; \
    uci commit ziti-edge-tunnel; \
    /etc/init.d/ziti-edge-tunnel enable; \
    /etc/init.d/ziti-edge-tunnel start"

  local deadline=$((SECONDS + ENROLL_TIMEOUT))
  while ((SECONDS < deadline)); do
    if ssh "$router" 'test -s /etc/openziti/identities/router.json &&
      test ! -e /etc/openziti/enroll.jwt &&
      /etc/init.d/ziti-edge-tunnel running' 2>/dev/null; then
      printf 'enrolled: identity %s active on %s\n' "$identity" "$router"
      return 0
    fi
    sleep 2
  done
  die "enrollment did not complete within ${ENROLL_TIMEOUT}s; check: ssh $router 'logread -e ziti-edge-tunnel | tail -50'"
}

main() {
  if [[ $# -lt 1 ]]; then
    usage >&2
    exit 2
  fi
  local command_name=$1
  shift
  case "$command_name" in
    install) cmd_install "$@" ;;
    update) cmd_update "$@" ;;
    enroll) cmd_enroll "$@" ;;
    -h | --help | help)
      usage
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
