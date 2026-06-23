#!/usr/bin/env bash
# Install Argo CD *as code* — pinned Helm chart + committed values.yaml.
# This cluster install is the ONLY manual bootstrap step; everything past it is GitOps.
set -euo pipefail

# Pin the chart, never 'latest'. argo/argo-cd 7.7.11 -> Argo CD v2.13.x.
ARGOCD_CHART_VERSION="7.7.11"
NAMESPACE="argocd"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

helm repo add argo https://argoproj.github.io/argo-helm
helm repo update argo

helm upgrade --install argocd argo/argo-cd \
  --namespace "${NAMESPACE}" --create-namespace \
  --version "${ARGOCD_CHART_VERSION}" \
  --values "${HERE}/argocd-values.yaml" \
  --wait

kubectl -n "${NAMESPACE}" rollout status deploy/argocd-server

echo "Initial admin password:"
kubectl -n "${NAMESPACE}" get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo

cat <<'EOF'

Argo CD installed (pinned Helm chart). Next:
  kubectl -n argocd port-forward svc/argocd-server 8080:443   # keep running
  argocd login localhost:8080 --username admin --password '<password-above>' --insecure
EOF
