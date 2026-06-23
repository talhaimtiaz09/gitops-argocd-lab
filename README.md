# argocd-gitops-config

Reusable **ArgoCD GitOps source-of-truth**: an app-of-apps deploying a multi-environment
workload with Kustomize **and** Helm, the External Secrets Operator as a managed
platform add-on, and secrets pulled from an external backend — **zero plaintext secrets
in Git**.

It has two entry points that share the same `base/`, `chart/`, and patterns:

- **`apps/` — kind / local lab.** dev + staging + prod `web` app, ESO, and a **Vault
  dev-mode** backend. Walk it via `docs/runbook-kind-core.md` and
  `docs/runbook-kind-secrets.md`.
- **`eks/` — real EKS cluster.** Same app-of-apps, but secrets come from **AWS Secrets
  Manager** and ESO authenticates via **IRSA** (no static keys). Designed to be
  referenced by a separate Terraform/EKS infra repo — see `eks/README.md`.

## Layout

```
bootstrap/   ArgoCD installed as code (pinned Helm chart + committed values)
project/     AppProjects — demo (kind workloads) · platform (kind add-ons) · eks
apps/        kind app-of-apps: dev/staging/prod + external-secrets + secrets-backend
base/        Kustomize base for the sample `web` app (Deployment, Service, ConfigMap)
overlays/    per-env Kustomize overlays: dev · staging · prod · eks
chart/       Helm chart used by the staging Application
platform/    kind secret backend: Vault dev pod + SecretStore + ExternalSecret
eks/         EKS entry point: app-of-apps + ESO(IRSA) + AWS Secrets Manager wiring
hooks/       PreSync / PostSync Job examples
extras/      legacy raw-install notes + broken-image patch (health demo)
docs/        runbooks, architecture diagram, learning tasks, EKS checklist
```

## Quick start

**Local (kind):**
```bash
./bootstrap/install-argocd.sh                 # or bootstrap/install.sh
kubectl apply -f project/demo-project.yaml -f project/platform-project.yaml
kubectl apply -f apps/root-app.yaml
argocd app list
```
Full walkthroughs: `docs/runbook-kind-core.md`, then `docs/runbook-kind-secrets.md`.

**EKS (referenced from your infra repo):**
```bash
kubectl apply -f project/eks-project.yaml
kubectl apply -f eks/apps/root-app.yaml
```
Set the three env-specific values first — see `eks/README.md`.

## Docs
- `docs/architecture.md` — end-to-end flow + the Vault→AWS / token→IRSA swap diagram
- `docs/runbook-kind-core.md` — ArgoCD core features lab
- `docs/runbook-kind-secrets.md` — secrets-via-GitOps lab (Vault + ESO + rotation)
- `docs/learn-argocd-tasks.md` — task-by-task exercises
- `eks/README.md` — how an EKS infra repo consumes this repo
