# Architecture — End-to-End Flow (scratch → running app with GitOps secrets)

This is the whole lab in one picture: from an empty kind cluster to a `web` app
running on credentials it never had hardcoded, with **zero plaintext secrets in Git**.

---

## 0 · The big picture

```
                          ┌───────────────────────────────────────────────┐
                          │                  Git repo                      │
                          │         (single source of truth)               │
                          │                                                │
                          │  bootstrap/   apps/    project/                 │
                          │  base/        overlays/ chart/   platform/      │
                          └───────────────────────┬───────────────────────┘
                                                   │ pulls desired state
                                                   ▼
   MANUAL (once)                          ┌──────────────────┐
   helm install argocd ───────────────►  │     Argo CD      │  reconciles Git → cluster
   (pinned chart, committed values)      │  (in `argocd` ns)│  (auto-sync / self-heal)
                                          └────────┬─────────┘
                                                   │ applies manifests
            ┌──────────────────────────────────────┼──────────────────────────────────┐
            ▼                                       ▼                                   ▼
   ┌─────────────────┐                    ┌──────────────────┐                ┌──────────────────┐
   │  app workloads  │                    │  platform add-on │                │  secret backend  │
   │  dev/staging/   │                    │  External Secrets│                │  Vault (dev mode)│
   │  prod  (web)    │                    │  Operator (ESO)  │                │  NON-PRODUCTION  │
   └─────────────────┘                    └──────────────────┘                └──────────────────┘
```

Only **one** manual command touches the cluster (the Argo CD install). Everything
else is reconstructed from Git.

---

## 1 · Bootstrap: Argo CD installed *as code*  (the ONLY manual step)

```
 you ──► helm repo add argo https://argoproj.github.io/argo-helm
     ──► helm install argocd argo/argo-cd  --version 7.7.11        (PINNED)
                                            --values bootstrap/values.yaml  (COMMITTED)
                          │
                          ▼
              ┌────────────────────────┐
              │  Argo CD running in     │   appVersion of chart pins the Argo CD image →
              │  namespace `argocd`     │   reproducible, no `latest`.
              └────────────────────────┘
```
From here on: **no more `kubectl apply` of workloads by hand.** Git drives everything.

---

## 2 · Bootstrap the projects + root app  (two applies → whole system)

```
 kubectl apply -f project/demo-project.yaml        (AppProject: app workloads, tight perms)
 kubectl apply -f project/platform-project.yaml    (AppProject: platform add-ons, broad perms)
 kubectl apply -f apps/root-app.yaml               (the app-of-apps root)
                          │
                          ▼
              ┌────────────────────────┐
              │   root Application      │  source: apps/  include:
              │   (app-of-apps)         │  {dev,staging,prod,external-secrets,secrets-backend}
              └───────────┬────────────┘
                          │ creates child Applications (ordered by sync-wave)
        ┌─────────────┬───┴─────────────┬──────────────────┬─────────────────────┐
        ▼             ▼                 ▼                  ▼                     ▼
     ┌──────┐     ┌────────┐        ┌──────┐        ┌──────────────┐     ┌─────────────────┐
     │ dev  │     │staging │        │ prod │        │external-     │     │ secrets-backend │
     │      │     │        │        │(MANUAL│        │secrets       │     │                 │
     │auto  │     │auto    │        │ gate)│        │ wave 1       │     │ wave 3          │
     └──────┘     └────────┘        └──────┘        └──────────────┘     └─────────────────┘
     Kustomize     Helm chart        Kustomize        ESO Helm chart       platform/ Kustomize
     overlays/dev  chart/            overlays/prod    (pinned 0.10.4)      Vault+Store+ExtSecret
```

**Sync-wave ordering matters:**
`external-secrets` (wave 1) installs the ESO controller + its CRDs **before**
`secrets-backend` (wave 3) tries to create `SecretStore`/`ExternalSecret` objects
(which require those CRDs to exist).

---

## 3 · Platform add-on: ESO installs itself (via Argo CD, not by hand)

```
 external-secrets Application ──► Helm chart charts.external-secrets.io @ 0.10.4
                                  installCRDs=true,  ServerSideApply=true
                          │
                          ▼
   namespace `external-secrets`:
     ┌────────────────────────────┐        + cluster-scoped CRDs:
     │ ESO controller (Deployment)│          - secretstores.external-secrets.io
     │ webhook, cert-controller    │          - externalsecrets.external-secrets.io
     └────────────────────────────┘            ...
```
This is the "Argo CD manages platform components" pattern — same slot that on EKS
installs kube-prometheus-stack, Loki, Karpenter.

---

## 4 · Secret backend + wiring  (secrets-backend app → platform/)

```
 secrets-backend Application ──► platform/ (Kustomize, into `dev` ns), internal sync-waves:

   wave 0   ┌─────────────────────────────┐
            │ Vault POD (dev mode)         │   in-memory, no persistence, single replica
            │ + Service `vault:8200`       │   ⚠ NON-PRODUCTION. token = "root"
            └─────────────────────────────┘
   wave 1   ┌─────────────────────────────┐
            │ SecretStore `vault-backend`  │   provider: vault → http://vault.dev.svc:8200
            │ (namespaced to `dev`)        │   auth: tokenSecretRef → Secret `vault-token`
            └─────────────────────────────┘
   wave 2   ┌─────────────────────────────┐
            │ ExternalSecret               │   refreshInterval: 15s
            │ `web-db-credentials`         │   maps Vault path → target K8s Secret
            └─────────────────────────────┘
```

**Two manual, out-of-band inputs (the only secret values — never in Git):**
```
  (a) kubectl -n dev create secret generic vault-token --from-literal=token=root
  (b) export DB_PASS='choose-a-dev-password'   # stays in your shell, never in Git
      kubectl -n dev exec vault -- vault kv put secret/web-db-credentials \
                                       username=webuser password=$DB_PASS
```

---

## 5 · The materialization loop (how the value gets into the cluster)

```
   Vault (secret/web-db-credentials)          Git (only a REFERENCE: path + keys)
        username=webuser                            ExternalSecret { key, property }
        password=<your-dev-value>                           │
              ▲                                             │ Argo CD synced this object
              │ (3) ESO reads using vault-token            ▼
              │                                   ┌──────────────────┐
              └───────────────────────────────────│   ESO controller │
                                                  └────────┬─────────┘
                                                           │ (4) writes a normal K8s Secret
                                                           ▼
                                              ┌────────────────────────────┐
                                              │ Secret `web-db-credentials` │  (in `dev`)
                                              │   username / password        │  owned by ESO
                                              └────────────────────────────┘
```
The password lives in Vault and in this runtime Secret — **never in Git**. Git holds
only the path/keys to fetch it.

---

## 6 · The app consumes it (close the loop)

```
   overlays/dev/db-credentials-patch.yaml
        envFrom:
          - configMapRef: web-config            ┌──────────────────────────┐
          - secretRef:   web-db-credentials ──► │   web Deployment (dev)    │
                                                │   env: username, password │
                                                └──────────────────────────┘
   prod / staging:  UNCHANGED  (no secretRef, manual prod gate intact)
```

Result:
```
  kubectl -n dev exec deploy/web -- env | grep -E 'username|password'   →  present
  git grep "$DB_PASS" -- '*.yaml'                                       →  no hits ✅
```

---

## 7 · Rotation

```
  vault kv put secret/web-db-credentials password=<NEW>   (same path)
        │
        ▼  within refreshInterval (15s)
  ESO re-pulls ──► updates Secret `web-db-credentials`
        │
        ▼  env-var consumer needs a restart to pick it up:
  kubectl -n dev rollout restart deploy/web
```
(Mounted-file consumers would update live; env vars need the restart — noted in RUN2 §8.)

---

## 8 · Declarative rebuild (prove zero drift / zero hidden state)

```
  kubectl -n argocd delete application root dev staging prod external-secrets secrets-backend
  kubectl delete ns dev staging prod external-secrets --ignore-not-found
        │  then re-apply the SAME bootstrap:
        ▼
  kubectl apply -f project/demo-project.yaml -f project/platform-project.yaml
  kubectl apply -f apps/root-app.yaml
        │
        ▼
  Everything comes back from Git: Argo CD (already installed) → root → 5 child apps →
  ESO → Vault → SecretStore/ExternalSecret → web.
  Re-supply only the two manual secret inputs (vault-token + the Vault value).
```

---

## What transfers 1:1 to EKS

```
  ✅ Argo CD installed as code (Helm, pinned)        — identical
  ✅ ESO installed as an Argo CD Application          — identical
  ✅ SecretStore / ExternalSecret + rotation          — identical
  🔁 Vault  ──────────────────────────►  AWS Secrets Manager   (swap provider block only)
  🔁 vault-token Secret  ─────────────►  IRSA (IAM role on ESO's ServiceAccount, no static keys)
```
Swap points are marked inline:
- provider Vault→AWS  →  `platform/secretstore.yaml`
- IRSA SA annotation  →  `apps/external-secrets.yaml`
```
       Vault dev (local)                          AWS Secrets Manager (EKS)
   provider: { vault: {...} }       ──►      provider: { aws: { service: SecretsManager }}
   auth: tokenSecretRef: vault-token ──►      auth: {} (IRSA-bound ServiceAccount)
```
