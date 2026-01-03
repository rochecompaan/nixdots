#!/usr/bin/env bash
set -euo pipefail

# Creates or updates a shared node-local host.v1 config and a per-node service
# using addressable terminators. The hosting identity is derived from the node
# as <node><dns-suffix> (default .compaan). The service name defaults to
# <node>-node-local and reuses the shared host config.
#
# Requirements:
# - Logged in with `ziti edge login` to the configured controller
# - Hosting identity exists: <node><dns-suffix>
#
# Defaults
CONTROLLER="ctrl.compaan.cloud:443"
DEFAULT_DNS_SUFFIX=".compaan"
DEFAULT_ADDRESS="127.0.0.1"
DEFAULT_HOST_CFG="node-local-host"

usage() {
  cat <<USAGE
Usage: $0 \\
  --node <name> \\
  --attrs <csv> \\
  [--address <ip-or-host>] \\
  [--dns-suffix <suffix>] \\
  [--service <service-name>] \\
  [--host-config <config-name>]

Creates/updates:
  - Shared host.v1 config (default: ${DEFAULT_HOST_CFG})
  - Per-node intercept.v1 config (<service>-intercept)
  - Service (<service>) referencing: <service>-intercept, ${DEFAULT_HOST_CFG}
  - Policies: Dial (roles from --attrs), Bind (@<node><dns-suffix>), SERP (@ziti-router)

Controller:
  Uses controller: ${CONTROLLER}

Example:
  $0 --node dauwalter --attrs admin
USAGE
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 2; }
}

main() {
  require_cmd ziti
  require_cmd awk
  require_cmd jq

  # Existence checker using Ziti CLI filter (server-side) to avoid pagination issues
  exists_by_name() {
    # $1: list subcommand (configs|services|service-policies|service-edge-router-policies)
    # $2: name to check
    local kind="$1" name="$2" filter
    filter=$(printf 'name = "%s"' "$name")
    if ziti edge list "$kind" "$filter" -j 2>/dev/null \
      | jq -e '.data | length > 0' >/dev/null; then
      return 0
    fi
    return 1
  }

  local NODE ATTRS_CSV ADDRESS DNS_SUFFIX SERVICE_NAME HOST_CFG
  NODE=""; ATTRS_CSV="";
  ADDRESS="${DEFAULT_ADDRESS}"; DNS_SUFFIX="${DEFAULT_DNS_SUFFIX}";
  SERVICE_NAME=""; HOST_CFG="${DEFAULT_HOST_CFG}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --node)
        [[ $# -ge 2 ]] || { echo "--node requires a value" >&2; exit 2; }
        NODE="$2"; shift 2;;
      --attrs)
        [[ $# -ge 2 ]] || { echo "--attrs requires a value" >&2; exit 2; }
        ATTRS_CSV="$2"; shift 2;;
      --address)
        [[ $# -ge 2 ]] || { echo "--address requires a value" >&2; exit 2; }
        ADDRESS="$2"; shift 2;;
      --dns-suffix)
        [[ $# -ge 2 ]] || { echo "--dns-suffix requires a value" >&2; exit 2; }
        DNS_SUFFIX="$2"; shift 2;;
      --service)
        [[ $# -ge 2 ]] || { echo "--service requires a value" >&2; exit 2; }
        SERVICE_NAME="$2"; shift 2;;
      --host-config)
        [[ $# -ge 2 ]] || { echo "--host-config requires a value" >&2; exit 2; }
        HOST_CFG="$2"; shift 2;;
      -h|--help)
        usage; exit 0;;
      *)
        echo "Unknown argument: $1" >&2; usage; exit 2;;
    esac
  done

  if [[ -z "$NODE" || -z "$ATTRS_CSV" ]]; then
    echo "Missing required arguments" >&2
    usage
    exit 2
  fi

  # Derived names
  local IDENTITY DNS_NAME SERVICE CFG_INTERCEPT POL_DIAL POL_BIND SERP_NAME ROUTER_NAME ROUTER_ROLE
  IDENTITY="${NODE}${DNS_SUFFIX}"
  DNS_NAME="$IDENTITY"
  if [[ -n "$SERVICE_NAME" ]]; then
    SERVICE="$SERVICE_NAME"
  else
    SERVICE="${NODE}-node-local"
  fi
  CFG_INTERCEPT="${SERVICE}-intercept"
  POL_DIAL="${SERVICE}-dial-policy"
  POL_BIND="${SERVICE}-bind-policy"
  SERP_NAME="${SERVICE}-only"
  ROUTER_NAME="ziti-router"
  ROUTER_ROLE="@${ROUTER_NAME}"

  # Ensure ziti session is valid
  if ! ziti edge list services >/dev/null 2>&1; then
    echo "No active ziti session. Login with:" >&2
    echo "  ziti edge login ${CONTROLLER} -u <user> -p <pass>" >&2
    exit 1
  fi

  # Build identity roles from attrs csv (comma-separated): #dev,#devops,...
  local IDENTITY_ROLES
  IDENTITY_ROLES="$(echo "$ATTRS_CSV" | awk -F',' '{for(i=1;i<=NF;i++){printf (i>1?",":"") "#"$i}}')"
  if [[ -z "$IDENTITY_ROLES" ]]; then
    echo "Failed to parse --attrs: $ATTRS_CSV" >&2; exit 2
  fi

  echo "Ensuring shared host config exists: $HOST_CFG"
  if exists_by_name configs "$HOST_CFG"; then
    echo "Config '$HOST_CFG' already exists; skipping update"
  else
    if ! ziti edge create config "$HOST_CFG" host.v1 "{\"address\":\"$ADDRESS\",\"allowedPortRanges\":[{\"low\":1,\"high\":65535}],\"allowedProtocols\":[\"udp\",\"tcp\"],\"forwardPort\":true,\"forwardProtocol\":true,\"listenOptions\":{\"bindUsingEdgeIdentity\":true}}"; then
      echo "Create failed; checking if it already exists by name..."
      if exists_by_name configs "$HOST_CFG"; then
        echo "Config '$HOST_CFG' exists; continuing"
      else
        echo "Failed to create config '$HOST_CFG' and it does not appear to exist." >&2
        exit 1
      fi
    fi
  fi

  echo "Ensuring intercept config exists: $CFG_INTERCEPT"
  if exists_by_name configs "$CFG_INTERCEPT"; then
    echo "Config '$CFG_INTERCEPT' already exists; skipping update"
  else
    ziti edge create config "$CFG_INTERCEPT" intercept.v1 "{\"addresses\":[\"$DNS_NAME\"],\"portRanges\":[{\"low\":1,\"high\":65535}],\"protocols\":[\"tcp\",\"udp\"],\"dialOptions\":{\"identity\":\"\$dst_hostname\"}}"
  fi

  echo "Ensuring service exists: $SERVICE"
  if exists_by_name services "$SERVICE"; then
    echo "Service '$SERVICE' already exists; skipping update"
  else
    ziti edge create service "$SERVICE" -c "$CFG_INTERCEPT,$HOST_CFG"
  fi

  echo "Ensuring policies exist for $SERVICE"
  if exists_by_name service-policies "$POL_DIAL"; then
    echo "Policy '$POL_DIAL' already exists; skipping update"
  else
    ziti edge create service-policy "$POL_DIAL" Dial --service-roles "@${SERVICE}" --identity-roles "$IDENTITY_ROLES"
  fi

  local BIND_SUBJ
  BIND_SUBJ="@${DNS_NAME}"
  if exists_by_name service-policies "$POL_BIND"; then
    echo "Policy '$POL_BIND' already exists; skipping update"
  else
    ziti edge create service-policy "$POL_BIND" Bind --service-roles "@${SERVICE}" --identity-roles "$BIND_SUBJ"
  fi

  echo "Ensuring service-edge-router policy exists: $SERP_NAME"
  if exists_by_name service-edge-router-policies "$SERP_NAME"; then
    echo "Service-edge-router policy '$SERP_NAME' already exists; skipping update"
  else
    ziti edge create service-edge-router-policy "$SERP_NAME" --service-roles "@${SERVICE}" --edge-router-roles "$ROUTER_ROLE"
  fi

  echo "Done. Service '$SERVICE' configured. Host config: '$HOST_CFG'. Identity for bind: '$DNS_NAME'. Router: $ROUTER_NAME"
}

main "$@"
