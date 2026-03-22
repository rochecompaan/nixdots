set shell := ["bash", "-euo", "pipefail", "-c"]

default:
  @just --list

mail-secrets: seal-webmutt-secret seal-openclaw-mail-secret

seal-webmutt-secret:
  kubectl create secret generic webmutt-gmail-secret \
    --namespace webmutt \
    --from-literal=GMAIL_ADDRESS="$(pass show private/login/accounts.google.com-rocheupfrontsoftware.co.za | grep -i '^username:' | sed 's/^[Uu]sername:[[:space:]]*//')" \
    --from-literal=GMAIL_APP_PASSWORD="$(pass show private/login/accounts.google.com-rocheupfrontsoftware.co.za | head -n1 | tr -d '[:space:]')" \
    --dry-run=client \
    -o yaml \
    | kubeseal --format=yaml \
    > argocd/homelab/webmutt/secret.yaml

seal-openclaw-mail-secret:
  kubectl create secret generic webmutt-gmail-secret \
    --namespace openclaw \
    --from-literal=GMAIL_ADDRESS="$(pass show private/login/accounts.google.com-rocheupfrontsoftware.co.za | grep -i '^username:' | sed 's/^[Uu]sername:[[:space:]]*//')" \
    --from-literal=GMAIL_APP_PASSWORD="$(pass show private/login/accounts.google.com-rocheupfrontsoftware.co.za | head -n1 | tr -d '[:space:]')" \
    --dry-run=client \
    -o yaml \
    | kubeseal --format=yaml \
    > argocd/homelab/openclaw-mail-sync/secret.yaml
