set shell := ["bash", "-euo", "pipefail", "-c"]

gmail_username_entry := "GMAIL_MAIL_SYNC_USERNAME"
gmail_webmutt_app_password_entry := "GMAIL_WEBMUTT_MAIL_SYNC"
gmail_openclaw_app_password_entry := "GMAIL_OPENCLAW_MAIL_SYNC"
openziti_controller_url := "https://ctrl.compaan.cloud/edge/management/v1"
openziti_login_controller := "ctrl.compaan.cloud:443"
openziti_username := "admin"
openziti_password_entry := "private/login/zac-ctrl.compaan.cloud-admin"

default:
  @just --list

mail-secrets: seal-webmutt-secret seal-openclaw-mail-secret

seal-webmutt-secret:
  kubectl create secret generic webmutt-gmail-secret \
    --namespace webmutt \
    --from-literal=GMAIL_ADDRESS="$(pass show {{gmail_username_entry}} | head -n1 | tr -d '[:space:]')" \
    --from-literal=GMAIL_APP_PASSWORD="$(pass show {{gmail_webmutt_app_password_entry}} | head -n1 | tr -d '[:space:]')" \
    --dry-run=client \
    -o yaml \
    | kubeseal --format=yaml \
    > argocd/homelab/webmutt/secret.yaml

seal-openclaw-mail-secret:
  kubectl create secret generic webmutt-gmail-secret \
    --namespace openclaw \
    --from-literal=GMAIL_ADDRESS="$(pass show {{gmail_username_entry}} | head -n1 | tr -d '[:space:]')" \
    --from-literal=GMAIL_APP_PASSWORD="$(pass show {{gmail_openclaw_app_password_entry}} | head -n1 | tr -d '[:space:]')" \
    --dry-run=client \
    -o yaml \
    | kubeseal --format=yaml \
    > argocd/homelab/openclaw-mail-sync/secret.yaml

seal-matrix-secret:
  mkdir -p argocd/homelab/infra; \
  tmpdir="$(mktemp -d)"; \
  trap 'rm -rf "$tmpdir"' EXIT; \
  form_secret="$(openssl rand -base64 48 | tr -d '\n')"; \
  macaroon_secret_key="$(openssl rand -base64 48 | tr -d '\n')"; \
  registration_shared_secret="$(openssl rand -base64 48 | tr -d '\n')"; \
  signing_key_id="a_$(openssl rand -hex 4)"; \
  signing_key_seed="$(openssl rand -base64 32 | tr -d '\n')"; \
  printf 'ed25519 %s %s\n' "$signing_key_id" "$signing_key_seed" > "$tmpdir/signing.key"; \
  kubectl create secret generic matrix \
    --namespace matrix \
    --from-file=signing.key="$tmpdir/signing.key" \
    --from-literal=form_secret="$form_secret" \
    --from-literal=macaroon_secret_key="$macaroon_secret_key" \
    --from-literal=registration_shared_secret="$registration_shared_secret" \
    --dry-run=client \
    -o yaml \
    | kubeseal --format=yaml \
    > argocd/homelab/infra/matrix-secret.yaml

ziti-edge-login:
  ziti edge login {{openziti_login_controller}} \
    -u "{{openziti_username}}" \
    -p "$(pass show {{openziti_password_entry}} | head -n1)"

seal-openziti-management-secret: ziti-edge-login
  mkdir -p argocd/homelab/miniziti-operator; \
  controller_url="${OPENZITI_CONTROLLER_URL:-{{openziti_controller_url}}}"; \
  username="${OPENZITI_USERNAME:-{{openziti_username}}}"; \
  password="${OPENZITI_PASSWORD:-$(pass show {{openziti_password_entry}} | head -n1 | tr -d '[:space:]')}"; \
  args=(create secret generic openziti-management \
    --namespace ziti \
    --from-literal="controllerUrl=$controller_url" \
    --from-literal="username=$username" \
    --from-literal="password=$password" \
    --dry-run=client \
    -o yaml); \
  if [[ -n "${OPENZITI_CA_BUNDLE_FILE:-}" ]]; then \
    args+=(--from-file="caBundle=${OPENZITI_CA_BUNDLE_FILE}"); \
  fi; \
  kubectl "${args[@]}" \
    | kubeseal --format=yaml \
    > argocd/homelab/miniziti-operator/openziti-management-secret.yaml
