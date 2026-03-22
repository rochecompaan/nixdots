set shell := ["bash", "-euo", "pipefail", "-c"]

gmail_username_entry := "GMAIL_MAIL_SYNC_USERNAME"
gmail_webmutt_app_password_entry := "GMAIL_WEBMUTT_MAIL_SYNC"
gmail_openclaw_app_password_entry := "GMAIL_OPENCLAW_MAIL_SYNC"

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
