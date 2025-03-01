#!/usr/bin/env bash
set -euo pipefail

# Default values
HOSTNAME=""
IP_ADDRESS=""
EXTRA_ARGS=()

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -*)
            EXTRA_ARGS+=("$1")
            shift
            ;;
        *)
            if [ -z "$HOSTNAME" ]; then
                HOSTNAME="$1"
            elif [ -z "$IP_ADDRESS" ]; then
                IP_ADDRESS="$1"
            else
                EXTRA_ARGS+=("$1")
            fi
            shift
            ;;
    esac
done

# Validate required arguments
if [ -z "$HOSTNAME" ] || [ -z "$IP_ADDRESS" ]; then
    echo "Usage: deploy-nixos <hostname> <ip-address> [extra nixos-anywhere args...]" >&2
    echo "Example: deploy-nixos myserver 192.168.1.100" >&2
    exit 1
fi

# Check if host configuration exists
if [ ! -f "hosts/${HOSTNAME}/default.nix" ]; then
    echo "Error: Configuration for host '${HOSTNAME}' not found in hosts/${HOSTNAME}/default.nix" >&2
    exit 1
fi

if [ -z "$IP_ADDRESS" ]; then
    echo "Error: Could not extract IP address from host configuration" >&2
    exit 1
fi

# Set target host and flake
TARGET_HOST="root@${IP_ADDRESS}"
FLAKE_TARGET=".#${HOSTNAME}"

# Create a temporary directory for secrets
TEMP_DIR=$(mktemp -d)

# Cleanup function
cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# Create SSH directory
install -d -m755 "$TEMP_DIR/etc/ssh"

# Decrypt and install SSH host keys
NIX_SECRETS_PATH=~/projects/nix-secrets/
sops --config $NIX_SECRETS_PATH/.sops.yaml --decrypt $NIX_SECRETS_PATH/secrets.yaml | \
    yq -r --arg name "$HOSTNAME" \
    '."ssh-keys".hosts.[$name].private' > "$TEMP_DIR/etc/ssh/ssh_host_ed25519_key"

# Set correct permissions
chmod 600 "$TEMP_DIR/etc/ssh/ssh_host_ed25519_key"

echo "Deploying $FLAKE_TARGET to $TARGET_HOST..." >&2
nixos-anywhere --extra-files "$TEMP_DIR" --flake "$FLAKE_TARGET" "${EXTRA_ARGS[@]}" "$TARGET_HOST"
