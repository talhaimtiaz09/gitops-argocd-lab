# Architecture — End-to-End Flow

How this system fits together, from a developer pushing code to a pod running on
Kubernetes with secrets it never had hardcoded — explained as one continuous flow.
Abstract enough to read top-to-bottom, detailed enough to leave nothing essential out.

---

## 0 · Two repos, one principle

GitOps separates **what the app is** from **where/how it runs**. That maps to two repos:

```
  ┌─────────────────────────────────────┐        ┌──────────────────────────────────────┐
  │  platform-status-dashboard (APP)     │        │  argocd-gitops-config  (THIS repo)    │
  │  Next.js source + Dockerfile + CI    │        │  ArgoCD Applications, Kustomize/Helm,  │
  │  → builds an IMAGE                    │        │  projects, secrets wiring → DESIRED    │
  │                                      │        │  STATE of the cluster                  │
  └───────────────┬─────────────────────┘        └──────────────────┬───────────────────┘
                  │ pushes image                                     │ declares which image
                  ▼                                                  ▼
            ghcr.io (registry)  ◄───────────── referenced by ──────────  manifests pin the tag
                  │                                                  │
                  └───────────────────────►  Kubernetes cluster  ◄───┘
                                   (ArgoCD pulls config from Git, pulls image from GHCR)
```

- **App repo** answers “what runs”: it produces a container image.
- **Config repo (this one)** answers “how it’s deployed”: it is the **single source of
  truth** ArgoCD continuously reconciles into the cluster.
- A human never runs `kubectl apply` for workloads. They change Git; ArgoCD does the rest.

---

## 1 · The 30,000-ft picture

```
 developer ──push──► APP repo ──CI──► GHCR image ─┐
                                                  │ (image tag referenced)
 developer ──push──► CONFIG repo (Git) ───────────┤
                                                  ▼
                                          ┌────────────────┐
                                          │     ArgoCD     │  reconciler (runs in `argocd` ns)
                                          │  desired = Git │  live = cluster ; diff → sync
                                          └───────┬────────┘
                                                  │ app-of-apps
        ┌──────────────┬───────────────┬──────────┴───────┬─────────────────────┐
        ▼              ▼               ▼                  ▼                     ▼
     dev (kust)    staging (helm)   prod (kust)     external-secrets       secrets-backend
     auto-sync     auto-sync        MANUAL gate      (ESO operator)        (Vault + wiring)
        │              │               │                  │                     │
        └──────────────┴───────────────┴── all render ───┴── the `web` workload ┘
                                          + the secret it consumes
```

Everything below expands each arrow.

---

## 2 · Component map (where each concern lives)

| Path | Role |
|------|------|
| `bootstrap/` | Install ArgoCD itself, as code (pinned Helm chart + committed values). The one manual step. |
| `project/` | **AppProjects** = guardrails: which repos, namespaces, and resource kinds each app may touch. |
| `apps/` | **kind/local app-of-apps**: a `root` Application that creates dev, staging, prod, ESO, and the Vault secret-backend apps. |
| `base/` | Kustomize **base** for the `web` app (Deployment, Service, ConfigMap). |
| `overlays/` | Per-environment Kustomize patches: `dev`, `staging`, `prod`, `eks`. |
| `chart/` | A **Helm chart** rendering the same `web` app — used by `staging` (two config tools, one platform). |
| `platform/` | kind secret backend: **Vault dev** pod + `SecretStore` + `ExternalSecret`. |
| `eks/` | **EKS entry point**: its own app-of-apps + ESO-with-IRSA + **AWS Secrets Manager** wiring + `web` (overlays/eks). |
| `hooks/` | PreSync / PostSync Job examples (migration, smoke test). |
| `docs/` | This file + runbooks + learning tasks + EKS checklist. |

---

## 3 · Flow part A — Source code becomes an image

```
 app/page.tsx, Dockerfile          (platform-status-dashboard repo)
        │  git push main
        ▼
 GitHub Actions (.github/workflows/build.yml)
        │  docker build (multi-stage, Next.js standalone, non-root)
        ▼
 ghcr.io/talhaimtiaz09/platform-status-dashboard : latest + <short-sha>
```

The image is a tiny self-contained Node server listening on **:3000**, exposing the
dashboard at `/` and a health probe at `/api/health`. The config repo pins this image
by tag — it does not build anything itself.

---

## 4 · Flow part B — Bootstrap: ArgoCD installed *as code*  (the only manual step)

```
 you ──► helm install argocd argo/argo-cd
            --version 7.7.11            (PINNED → ArgoCD image is pinned too)
            --values bootstrap/argocd-values.yaml   (COMMITTED, port-forward friendly)
        │
        ▼
 ArgoCD running in namespace `argocd`  ── access via `kubectl port-forward` only (no LoadBalancer)
```

`bootstrap/install-argocd.sh` wraps this. After it, **nothing else is applied by hand**
except the project + root Application that hand control to GitOps.

---

## 5 · Flow part C — App-of-apps: one apply fans out to many

```
 kubectl apply project/demo-project.yaml project/platform-project.yaml
 kubectl apply apps/root-app.yaml
        │
        ▼
 ┌──────────────────────────┐
 │  root  (Application)      │  source: path `apps/`, include {dev,staging,prod,
 │  project: demo-project    │           external-secrets,secrets-backend}
 └───────────┬──────────────┘
             │ creates 5 child Applications (each is just another manifest in apps/)
   ┌─────────┼───────────┬───────────────────┬──────────────────────┐
   ▼         ▼           ▼                   ▼                      ▼
  dev      staging      prod          external-secrets        secrets-backend
 (wave —)  (wave —)   (wave —)          (wave 1)                (wave 3)
```

**Why app-of-apps:** deleting `root` + re-applying it rebuilds the entire tree from Git.
There is no hidden state — the cluster is a pure function of the repo.

### Guardrails (AppProjects)
Each Application names a **project** that constrains it:

| Project | Source repos | Destinations (ns) | Allowed kinds |
|---------|--------------|-------------------|---------------|
| `demo-project` | this repo | dev, staging, prod, argocd | tight: ConfigMap, Service, Deployment, Pod, Job, HPA, SecretStore, ExternalSecret, Application |
| `platform-project` | this repo + ESO chart | external-secrets, argocd | broad (`*/*`) — ESO installs CRDs/ClusterRoles/webhooks |
| `eks-project` | this repo + ESO chart | web, external-secrets, argocd | broad (`*/*`) — EKS env, single project for the demo |

Least-privilege is the point: app workloads can’t install cluster-scoped things; only
the platform project can.

---

## 6 · Flow part D — Rendering the `web` workload (two config tools)

The same app is expressed two ways, proving ArgoCD is tool-agnostic:

```
            base/ (Deployment+Service+ConfigMap)
                 │
   ┌─────────────┼───────────────────────────┐
   ▼ Kustomize   ▼ Kustomize                  ▼ Helm
 overlays/dev  overlays/prod / overlays/eks   chart/  (staging)
```

| Env | Tool | Source | Sync policy | Replicas | Secret backend env |
|-----|------|--------|-------------|----------|--------------------|
| dev | Kustomize | `overlays/dev` | auto-sync + **self-heal** | 1 | `vault-dev` |
| staging | Helm | `chart/` | auto-sync, self-heal **off** | 2 | `none` |
| prod | Kustomize | `overlays/prod` | **manual sync** (safety gate) | per patch | `none` |
| eks | Kustomize | `overlays/eks` | auto-sync + self-heal | 2 | `aws-secrets-manager` |

Every variant pins the image `ghcr.io/talhaimtiaz09/platform-status-dashboard:latest`,
container port **3000**, probes on `/api/health`, Service `80 → 3000`.

**Env injected into the pod** (this is what the dashboard renders):
- `ENVIRONMENT`, `SECRET_BACKEND`, `IMAGE_TAG` → from the `web-config` ConfigMap (`envFrom`)
- `POD_NAME`, `POD_NAMESPACE`, `NODE_NAME` → Kubernetes **Downward API**
- `username`, `password` → from the `web-db-credentials` Secret (`envFrom`, dev + eks only)

---

## 7 · Flow part E — Secrets via GitOps (the heart)

Goal: **no secret value ever lives in Git.** Git holds only a *reference*; an operator
pulls the real value into a normal Kubernetes Secret at runtime.

### The materialization loop (same shape in both environments)

```
   secret backend                 Git (reference only)
   (Vault / AWS SM)               ExternalSecret { key, property }
        ▲                                  │  (ArgoCD synced this object)
        │ (3) operator reads               ▼
        │     using its identity   ┌──────────────────┐
        └──────────────────────────│  ESO controller  │  (External Secrets Operator)
                                   └────────┬─────────┘
                                            │ (4) writes a normal K8s Secret
                                            ▼
                                  ┌────────────────────────────┐
                                  │ Secret `web-db-credentials` │  username / password
                                  └────────────┬───────────────┘
                                               │ (5) envFrom
                                               ▼
                                        web Deployment (dev / eks)
```

ESO is itself installed **by ArgoCD** as a pinned Helm Application (`external-secrets`
chart `0.10.4`, sync-wave 1) — so even the operator is GitOps, not a manual `helm install`.

### Ordering (sync-waves) so it can’t race
```
 external-secrets (wave 1)  ─►  CRDs + controller exist
        └─► secrets-backend (wave 3)
                 ├─ Vault pod        (wave 0 within the app)
                 ├─ SecretStore      (wave 1)
                 └─ ExternalSecret   (wave 2)  ─► creates web-db-credentials
```

### kind vs EKS — only the backend + auth differ
```
                       kind (local lab)                 EKS (production-shaped)
 backend            Vault dev pod (in-cluster)          AWS Secrets Manager
 store              platform/secretstore.yaml           eks/secrets/aws-secret-store.yaml
 provider block     provider: { vault: ... }            provider: { aws: SecretsManager }
 ESO auth           tokenSecretRef → `vault-token`       auth: {} → IRSA role on ESO's SA
                    (created out-of-band, never in Git)  (no static AWS keys at all)
 refresh            15s (fast rotation demo)             1h
 ExternalSecret     IDENTICAL                            IDENTICAL
```

The `ExternalSecret`, the app-of-apps pattern, and the `envFrom` consumption are byte-for-
byte the same. Swapping Vault→AWS is two edits, marked inline in
`platform/secretstore.yaml` and `eks/apps/external-secrets-operator.yaml`.

### The two manual, out-of-band inputs (the only secret material, never committed)
- kind: `kubectl -n dev create secret generic vault-token --from-literal=token=root`,
  then write a value into Vault at `secret/web-db-credentials`.
- EKS: create the IAM role (IRSA) + the Secrets Manager secret via Terraform; ESO reads it
  with no static keys.

---

## 8 · Flow part F — The app closes the loop

```
 web pod boots ─► reads its env ─► renders the dashboard:
      Environment / Namespace / Pod / Node / Image / Secret backend
      DB credentials: "Loaded ✓"  user: webuser   (password never rendered)
```

The dashboard makes the whole platform *visible*: which env/pod served the page, where the
DB credentials came from, and that no static keys are baked into the image. Proof:
`git grep <the password>` over the manifests returns nothing — only the reference exists.

---

## 9 · The reconciliation model (why it stays correct)

ArgoCD continuously compares **desired (Git)** vs **live (cluster)** for every app:

```
   Git change ─► OutOfSync ─► (auto-sync?) ─► apply ─► Synced
   Live drift  ─► OutOfSync ─► (self-heal?) ─► revert ─► Synced
```

- **auto-sync** (dev/staging/eks): Git is law; pushes apply automatically.
- **self-heal** (dev/eks): manual `kubectl` edits are reverted to match Git.
- **prune**: resources deleted from Git are deleted from the cluster.
- **manual gate** (prod): never auto-applies; a human runs `argocd app sync prod`. A
  deny **sync window** further freezes prod on a schedule.
- **Sync ≠ Health**: an app can be *Synced* (matches Git) yet *Degraded* (e.g. bad image) —
  two independent signals.
- **hooks** (`hooks/`): PreSync migration Job runs before, PostSync smoke-test after.

---

## 10 · One change, end to end

What happens when a developer ships a UI tweak:

```
 1. edit app/page.tsx           (app repo)         ──► git push
 2. CI builds + pushes          ghcr.io/...:<sha>  ──► new image exists
 3. bump the tag in Git         (config repo)      ──► git push        [or use latest + restart]
 4. ArgoCD detects OutOfSync    desired ≠ live
 5. ArgoCD syncs                rolls the Deployment to the new image
 6. pod boots, probes pass      Synced + Healthy
```

A config-only change (replicas, env, a new ExternalSecret) skips steps 1–2 entirely — just
edit Git and ArgoCD converges.

---

## 11 · Rebuild-from-Git (zero hidden state)

```
 delete the root app(s) + namespaces
 re-apply: projects → root-app
 ArgoCD reconstructs: ESO → Vault/SM → SecretStore/ExternalSecret → web
 re-supply ONLY the out-of-band secret material
```

If the cluster is a function of Git, disaster recovery is just “apply the repo again.” On
EKS this same property is the timed DR metric (the from-zero `terraform apply` + sync).

---

## 12 · Security posture (what this design buys)

- **No plaintext secrets in Git** — only references; values live in Vault / AWS SM.
- **No static cloud keys on EKS** — ESO authenticates via IRSA (IAM role on its SA).
- **Least-privilege projects** — workloads can’t install cluster-scoped resources.
- **No public exposure** — ArgoCD/Grafana reached via port-forward, never `LoadBalancer`.
- **Pinned everything** — ArgoCD chart, ESO chart, Vault image, app image, Node base — no
  `latest`-driven drift on the platform layer.
- **Auditable & reversible** — every change is a Git commit; rollback is `git revert` or
  `argocd app rollback`.
