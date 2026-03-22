set shell := ["bash", "-euo", "pipefail", "-c"]

default:
  @just --list

seal-webmutt-secret:
  kubectl create secret generic webmutt-gmail-secret \
    --namespace webmutt \
    --from-literal=GMAIL_ADDRESS="$$(pass show private/login/accounts.google.com-rocheupfrontsoftware.co.za | grep -i '^username:' | sed 's/^[Uu]sername:[[:space:]]*//')" \
    --from-literal=GMAIL_APP_PASSWORD="$$(pass show private/login/accounts.google.com-rocheupfrontsoftware.co.za | head -n1)" \
    --dry-run=client \
    -o yaml \
    | kubeseal --format=yaml \
    > argocd/homelab/webmutt/secret.yaml

seal-openclaw-mail-secret:
  kubectl create secret generic webmutt-gmail-secret \
    --namespace openclaw \
    --from-literal=GMAIL_ADDRESS="$$(pass show private/login/accounts.google.com-rocheupfrontsoftware.co.za | grep -i '^username:' | sed 's/^[Uu]sername:[[:space:]]*//')" \
    --from-literal=GMAIL_APP_PASSWORD="$$(pass show private/login/accounts.google.com-rocheupfrontsoftware.co.za | head -n1)" \
    --dry-run=client \
    -o yaml \
    | kubeseal --format=yaml \
    > argocd/homelab/openclaw-mail-sync/secret.yaml
