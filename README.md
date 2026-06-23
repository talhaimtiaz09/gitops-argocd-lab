# gitops-argocd-lab — ArgoCD multi-environment lab

A complete, declarative GitOps setup covering every major ArgoCD feature.
Work through **LEARN.md** task by task.

## Before you push
Replace the repo placeholder with your GitHub username:
```bash
grep -rl REPLACE_ME . | xargs sed -i 's/REPLACE_ME/YOURNAME/g'
```

## Layout
- `apps/`      app-of-apps root + dev/staging/prod Applications
- `base/`      Kustomize base (Deployment, Service, ConfigMap)
- `overlays/`  per-env Kustomize overlays (dev/staging/prod)
- `chart/`     Helm chart used by the staging Application
- `project/`   AppProject (guardrails, sync window)
- `hooks/`     PreSync / PostSync Job examples
- `extras/`    install notes + broken-image patch for the health task

## Quick start
```bash
kubectl apply -f project/demo-project.yaml
kubectl apply -f apps/root-app.yaml
argocd app list
```
