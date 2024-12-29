#!/usr/bin/env bash

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: $0 <hostname>"
    exit 1
fi

HOSTNAME=$1
KEY_FILE="./hosts/${HOSTNAME}/ssh_key"
KEY_NAME="ssh_key"
SECRETS_DIR="./secrets/${HOSTNAME}"
SECRETS_FILE="${SECRETS_DIR}/secrets.yaml"

# Create secrets directory if it doesn't exist
mkdir -p "${SECRETS_DIR}"

# Generate the SSH key pair
ssh-keygen -t ed25519 -C "${HOSTNAME}" -f "$KEY_FILE" -N ""

# Generate age key from ed25519 private key
echo "Generating age key from ed25519 key..." >&2
AGE_PUB=$(ssh-to-age < "${KEY_FILE}.pub")
echo "Age key generated: ${AGE_PUB}" >&2

# Add Age key to .sops.yaml
echo "Adding age key to .sops.yaml..." >&2

# Add the key to the keys section and creation rules
TEMP_FILE=$(mktemp)

# First add the new key after the last key entry
sed -i '/^creation_rules:/i\  - \&'"${HOSTNAME}"' '"${AGE_PUB}"'' .sops.yaml

# Then add the creation rule before the shared rule
sed -i "/path_regex: secrets\/shared/i\\  - path_regex: secrets\/${HOSTNAME}\/[^/]\\+\\.(yaml|json|env|ini)$\\n    key_groups:\\n      - age:\\n          - *roche\\n          - *${HOSTNAME}" .sops.yaml

# Encrypt and store the private key
PRIVATE_KEY=$(cat "$KEY_FILE")

# Create a temporary unencrypted file
TEMP_SECRETS=$SECRETS_FILE.tmp.yaml
echo "${KEY_NAME}: |" > "$TEMP_SECRETS"
echo "${PRIVATE_KEY}" | sed 's/^/  /' >> "$TEMP_SECRETS"

# Encrypt the temporary file and save to final location
sops --encrypt "$TEMP_SECRETS" > "$SECRETS_FILE"

# Clean up temporary file
rm "$TEMP_SECRETS"

# Remove unencrypted private key
rm "$KEY_FILE"

echo "SSH key pair generated:"
echo "- Private key encrypted and stored in ${SECRETS_FILE}"
echo "- Public key stored in hosts/${HOSTNAME}/${KEY_NAME}.pub"
