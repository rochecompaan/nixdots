#!/usr/bin/env bash
set -euo pipefail

# Creates or updates an OpenZiti service with intercept + host configs, dial/bind policies,
# and a service→edge-router policy pinned to a specific cluster's router.
#
# Required args (flags):
#   --host-dns <k8s-fqdn>                  e.g. argocd-server.argocd.svc.cluster.local
#   --port <int>                           kubernetes service port (e.g., 80 or 443)
#   --attrs <csv>                          identity attributes allowed to dial (e.g., devops,dev,edtech)
#   --intercept <host:port>                intercept host:port (e.g., argocd.compaan:80)
# Optional:
#   --name <service-name>                  override derived service name
#
# Conventions:
# - Generated names (if --name not provided):
#   service: <intercept-host> with dots replaced by dashes (port omitted)
#   configs: <service>-intercept, <service>-host
#   policies: <service>-dial-policy, <service>-bind-policy
#   service-edge-router-policy: <service>-only

CONTROLLER="ctrl.compaan.cloud:443"

usage() {
  cat <<USAGE
Usage: $0 \\
  --host-dns <k8s-fqdn> \\
  --port <int> \\
  --attrs <csv> \\
  --intercept <host:port> \\
  [--name <service-name>]

Controller:
  Uses controller: ${CONTROLLER}

Examples:
  $0 \\
  --host-dns argocd-server.argocd.svc.cluster.local \\
  --port 80 \\
  --attrs devops \\
  --intercept argocd.compaan:80
USAGE
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 2; }
}

parse_kv() { :; }

main() {
  require_cmd ziti
  require_cmd awk

  HOST_DNS=""; PORT=""; ATTRS_CSV=""; INTERCEPT=""; NAME_OVERRIDE=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --host-dns)
        [[ $# -ge 2 ]] || { echo "--host-dns requires a value" >&2; exit 2; }
        HOST_DNS="$2"; shift 2;;
      --port)
        [[ $# -ge 2 ]] || { echo "--port requires a value" >&2; exit 2; }
        PORT="$2"; shift 2;;
      --attrs)
        [[ $# -ge 2 ]] || { echo "--attrs requires a value" >&2; exit 2; }
        ATTRS_CSV="$2"; shift 2;;
      --intercept)
        [[ $# -ge 2 ]] || { echo "--intercept requires a value (host:port)" >&2; exit 2; }
        INTERCEPT="$2"; shift 2;;
      --name|--service)
        [[ $# -ge 2 ]] || { echo "--name/--service requires a value" >&2; exit 2; }
        NAME_OVERRIDE="$2"; shift 2;;
      -h|--help)
        usage; exit 0;;
      *)
        echo "Unknown argument: $1" >&2; usage; exit 2;;
    esac
  done

  if [[ -z "$HOST_DNS" || -z "$PORT" || -z "$ATTRS_CSV" || -z "$INTERCEPT" ]]; then
    echo "Missing required arguments" >&2
    usage
    exit 2
  fi

  # Derive names
  local intercept_host intercept_port
  intercept_host="${INTERCEPT%%:*}"
  intercept_port="${INTERCEPT##*:}"
  if [[ -z "$intercept_host" || -z "$intercept_port" ]]; then
    echo "--intercept requires host:port" >&2; exit 2
  fi

  # Validate numeric ports
  if ! [[ "$intercept_port" =~ ^[0-9]+$ ]] || ! [[ "$PORT" =~ ^[0-9]+$ ]]; then
    echo "--port and intercept port must be integers" >&2; exit 2
  fi

  local service_name
  if [[ -n "${NAME_OVERRIDE:-}" ]]; then
    service_name="$NAME_OVERRIDE"
  else
    service_name="${intercept_host//./-}"
  fi

  local cfg_intercept cfg_host pol_dial pol_bind serp_name router_name router_role
  cfg_intercept="${service_name}-intercept"
  cfg_host="${service_name}-host"
  pol_dial="${service_name}-dial-policy"
  pol_bind="${service_name}-bind-policy"
  serp_name="${service_name}-only"
  router_name="ziti-router"
  router_role="@${router_name}"

  # Ensure ziti session is valid
  if ! ziti edge list services >/dev/null 2>&1; then
    echo "No active ziti session. Login with:" >&2
    echo "  ziti edge login ${CONTROLLER} -u <user> -p <pass>" >&2
    exit 1
  fi

  # Build identity roles from attrs csv (comma-separated): #dev,#devops,...
  local identity_roles
  identity_roles="$(echo "$ATTRS_CSV" | awk -F',' '{for(i=1;i<=NF;i++){printf (i>1?",":"") "#"$i}}')"
  if [[ -z "$identity_roles" ]]; then
    echo "Failed to parse --attrs: $ATTRS_CSV" >&2; exit 2
  fi

  echo "Creating/updating configs: $cfg_intercept, $cfg_host"
  if ziti edge list configs | awk 'NR>2{print $2}' | grep -qx "$cfg_intercept"; then
    ziti edge update config "$cfg_intercept" -d "{\"addresses\":[\"$intercept_host\"],\"portRanges\":[{\"low\":$intercept_port,\"high\":$intercept_port}],\"protocols\":[\"tcp\"]}"
  else
    ziti edge create config "$cfg_intercept" intercept.v1 "{\"addresses\":[\"$intercept_host\"],\"portRanges\":[{\"low\":$intercept_port,\"high\":$intercept_port}],\"protocols\":[\"tcp\"]}"
  fi

  if ziti edge list configs | awk 'NR>2{print $2}' | grep -qx "$cfg_host"; then
    ziti edge update config "$cfg_host" -d "{\"address\":\"$HOST_DNS\",\"port\":$PORT,\"protocol\":\"tcp\"}"
  else
    ziti edge create config "$cfg_host" host.v1 "{\"address\":\"$HOST_DNS\",\"port\":$PORT,\"protocol\":\"tcp\"}"
  fi

  echo "Creating/updating service: $service_name"
  if ziti edge list services | awk 'NR>2{print $2}' | grep -qx "$service_name"; then
    ziti edge update service "$service_name" -c "$cfg_intercept,$cfg_host"
  else
    ziti edge create service "$service_name" -c "$cfg_intercept,$cfg_host"
  fi

  echo "Creating/updating policies for $service_name"
  if ziti edge list service-policies | awk 'NR>2{print $2}' | grep -qx "$pol_dial"; then
    ziti edge update service-policy "$pol_dial" --service-roles "@${service_name}" --identity-roles "$identity_roles"
  else
    ziti edge create service-policy "$pol_dial" Dial --service-roles "@${service_name}" --identity-roles "$identity_roles"
  fi

  if ziti edge list service-policies | awk 'NR>2{print $2}' | grep -qx "$pol_bind"; then
    ziti edge update service-policy "$pol_bind" --service-roles "@${service_name}" --identity-roles "$router_role"
  else
    ziti edge create service-policy "$pol_bind" Bind --service-roles "@${service_name}" --identity-roles "$router_role"
  fi

  echo "Creating/updating service-edge-router policy: $serp_name"
  if ziti edge list service-edge-router-policies | awk 'NR>2{print $2}' | grep -qx "$serp_name"; then
    ziti edge update service-edge-router-policy "$serp_name" --service-roles "@${service_name}" --edge-router-roles "$router_role"
  else
    ziti edge create service-edge-router-policy "$serp_name" --service-roles "@${service_name}" --edge-router-roles "$router_role"
  fi

  echo "Done. Service '$service_name' configured.'"
}

main "$@"
