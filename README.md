# gitops-argocd-lab — ArgoCD multi-environment lab

A complete, declarative GitOps setup covering every major ArgoCD feature.
Work through **LEARN.md** task by task.

## Before you push
Replace the repo placeholder with your GitHub username:
```bash
grep -rl REPLACE_ME . | xargs sed -i 's/REPLACE_ME/YOURNAME/g'
```

## Layout
- `bootstrap/` Argo CD installed *as code* (pinned Helm chart + committed values)
- `apps/`      app-of-apps root + dev/staging/prod + platform Applications
- `base/`      Kustomize base (Deployment, Service, ConfigMap)
- `overlays/`  per-env Kustomize overlays (dev/staging/prod)
- `chart/`     Helm chart used by the staging Application
- `platform/`  Vault dev backend + ESO SecretStore/ExternalSecret (secrets via GitOps)
- `project/`   AppProjects — `demo-project` (workloads) + `platform-project` (add-ons)
- `hooks/`     PreSync / PostSync Job examples
- `extras/`    legacy raw install notes + broken-image patch for the health task

See **RUN.md** for the core lab and **RUN2.md** for the secrets-via-GitOps phase.

## Quick start
```bash
kubectl apply -f project/demo-project.yaml
kubectl apply -f apps/root-app.yaml
argocd app list
```
