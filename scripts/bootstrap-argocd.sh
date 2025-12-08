#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then
  echo "Usage: $0 <environment> [repo-url] [branch]"
  exit 1
fi

ENV="${1:-homelab}"
REPO_URL="${2:-$(git config --get remote.origin.url)}"
BRANCH="${3:-main}"

# Create the repository secret
kubectl apply -f - << EOF
apiVersion: v1
kind: Secret
metadata:
  name: github-repo-secret
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: ${REPO_URL}
EOF

# Create the root application
kubectl apply -f - << EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
  labels:
    app.kubernetes.io/name: root
spec:
  destination:
    namespace: argocd
    server: https://kubernetes.default.svc
  project: default
  source:
    path: argocd/${ENV}/apps
    repoURL: ${REPO_URL}
    targetRevision: ${BRANCH}
  syncPolicy:
    automated:
      allowEmpty: true
      prune: true
      selfHeal: true
    syncOptions:
    - allowEmpty=true
EOF
