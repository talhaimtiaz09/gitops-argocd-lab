# bootstrap/ — Argo CD installed *as code*

Replaces the old raw `kubectl apply -f .../install.yaml` (see `extras/argocd-install.txt`,
kept only for reference). Argo CD is now installed from its **official Helm chart at a
pinned version**, with values committed here — exactly how you'd do it on EKS.

## Exact commands

```bash
# 1. Add the Argo Helm repo
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update argo

# 2. Install Argo CD — PINNED chart version, committed values
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --version 7.7.11 \
  --values bootstrap/argocd-values.yaml \
  --wait

# 3. Admin password + UI
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
kubectl -n argocd port-forward svc/argocd-server 8080:443   # keep running
argocd login localhost:8080 --username admin --password '<password>' --insecure
```

Or just run `./bootstrap/install-argocd.sh` (does steps 1–3).

## Why pinned?
`argo/argo-cd` **7.7.11** maps to Argo CD **v2.13.x**. Pinning the chart pins the
Argo CD image — no surprise upgrades, reproducible from Git. Never use `latest`.

> The cluster install is the only thing done by hand. Everything after it
> (projects, apps, platform add-ons, secrets wiring) is reconstructed from Git.
