# ArgoCD Speed Run 2 — Secrets via GitOps (Follow Along)

Rehearse the EKS Phase 2 secrets flow locally on kind, free. You'll install ArgoCD
*as code*, have ArgoCD manage a platform add-on (External Secrets Operator), and
sync a secret from a backend into your app — proving no plaintext secret lives in Git.

Same style as `runbook-kind-core.md`: run each block, check **👀 you should see**, move on.
Total time: ~45–60 min. See `architecture.md` for the end-to-end picture.

> Prereqs: this repo + `kind`, `kubectl`, `helm`, and the `argocd` CLI installed.
> Everything new here also lives in Git — nothing created by hand except the cluster
> install and the two secret *values* (the whole point: values never touch Git).

---

## 0 · Cluster up (if not already)
```bash
kind create cluster --name argo-lab     # skip if it already exists
kubectl get nodes
helm version
```
👀 Nodes Ready, helm responds.

---

## 1 · Install ArgoCD *as code* (Helm, version-pinned)
Goal: stop using raw `kubectl apply` for ArgoCD. Install it via its official Helm
chart at a pinned version, the way you will on EKS.

```bash
# pinned chart + committed values (see bootstrap/argocd-values.yaml)
./bootstrap/install-argocd.sh

# UI in another terminal (keep it running):
kubectl -n argocd port-forward svc/argocd-server 8080:443

# login (password is printed by install.sh)
argocd login localhost:8080 --username admin \
  --password "$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)" \
  --insecure
```
👀 ArgoCD pods Running; you logged in; the install is reproducible from a committed
values file + pinned version (`argo/argo-cd` 7.7.11), not a one-off command.

*(This is the "ArgoCD itself is code" golden rule. The cluster install is the only
manual bootstrap; everything past it is GitOps.)*

---

## 2 · Re-deploy your existing apps + projects
```bash
kubectl apply -f project/demo-project.yaml
kubectl apply -f project/platform-project.yaml
kubectl apply -f apps/root-app.yaml
argocd app list
```
👀 The root app appears and fans out: **dev, staging, prod, external-secrets,
secrets-backend**. dev/staging come up healthy; prod waits at its manual gate.

```bash
argocd app sync prod        # approve prod explicitly (manual gate preserved)
```

---

## 3 · Let ArgoCD manage a platform add-on (External Secrets Operator)
Goal: ESO is installed *by* ArgoCD as an Application pointing at the ESO Helm chart
(pinned `0.10.4`) — not by you running helm by hand. It's sync-wave 1, so it lands first.

```bash
argocd app sync external-secrets        # (auto-syncs anyway; this just forces it now)
argocd app get external-secrets | grep -E "Sync Status|Health Status"
kubectl -n external-secrets get pods
kubectl get crds | grep external-secrets.io
```
👀 `external-secrets` app **Synced + Healthy**; ESO controller pods Running; CRDs
(`secretstores`, `externalsecrets`, ...) now exist.

*(In production this same slot installs ESO, kube-prometheus-stack, Loki, Karpenter —
all as ArgoCD Applications.)*

---

## 4 · Stand up the secret backend (Vault dev mode) + seed a credential
Goal: a stand-in for AWS Secrets Manager. Vault dev-mode is in-memory, zero config.
The `secrets-backend` app (sync-wave 3) already deployed the Vault pod for you.

```bash
kubectl -n dev get pod vault                 # deployed by the secrets-backend app
kubectl -n dev wait --for=condition=Ready pod/vault --timeout=60s

# (manual #1) give ESO a token to talk to Vault — NEVER committed to Git:
kubectl -n dev create secret generic vault-token --from-literal=token=root

# (manual #2) write the fake DB credential into Vault.
# Keep the value in a SHELL var so it never lands in a file → the step-7 proof stays honest:
export DB_PASS='choose-a-dev-password'   # your choice; lives in your shell, never in Git
kubectl -n dev exec vault -- sh -c "
  export VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root
  vault kv put secret/web-db-credentials username=webuser password=$DB_PASS"

# read it back to confirm:
kubectl -n dev exec vault -- sh -c '
  export VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root
  vault kv get secret/web-db-credentials'
```
👀 Vault pod Running; you can read the test secret back from inside the pod.

---

## 5 · Wire ESO: SecretStore → ExternalSecret
Goal: Git holds only a *reference*; ESO pulls the real value into a normal K8s Secret.
Both objects are already in `platform/` and synced by the `secrets-backend` app.

```bash
argocd app sync secrets-backend
kubectl -n dev get secretstore vault-backend
kubectl -n dev get externalsecret web-db-credentials
kubectl -n dev get secret web-db-credentials          # created by ESO
```
👀 `SecretStore` Valid, `ExternalSecret` SecretSynced=True, and ESO created the
`web-db-credentials` Secret automatically. The actual password is NOWHERE in Git —
only the path/reference is.

> If the ExternalSecret shows an auth error, you likely skipped `vault-token` (step 4)
> or haven't written the value yet. Re-run those, then `argocd app sync secrets-backend`.

---

## 6 · Consume the secret in your app
Goal: close the loop — the `web` Deployment (dev overlay) pulls the credential via
`envFrom`. prod/staging are untouched.

```bash
argocd app sync dev
kubectl -n dev rollout status deploy/web
kubectl -n dev exec deploy/web -- env | grep -E '^username=|^password='
```
👀 The pod exposes the credential as env vars; the value is present in the running
container — but it never appeared in Git.

---

## 7 · Prove the security posture (the whole point)
```bash
# search every committed YAML manifest — the value must not be there:
git grep -n "$DB_PASS" -- '*.yaml' \
  && echo "FOUND IN A MANIFEST ✗" || echo "value NOT in any YAML manifest ✅"

# the manifests only ever reference the Vault path/keys, never a value:
git grep -n 'web-db-credentials' -- platform/externalsecret.yaml
```
👀 The secret value has **no hits** in any committed manifest; the only matches are the
*reference* (`web-db-credentials` path + `username`/`password` keys). The app runs with
credentials it never had hardcoded — the Phase 2 "no static keys" proof, minus AWS/IRSA.

---

## 8 · Test rotation
Goal: rotation is the feature that makes this worth it. `refreshInterval` is `15s`.

```bash
# change the value at the same Vault path:
export DB_PASS='choose-a-new-password'
kubectl -n dev exec vault -- sh -c "
  export VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root
  vault kv put secret/web-db-credentials username=webuser password=$DB_PASS"

sleep 20                                   # wait out the refreshInterval
kubectl -n dev get secret web-db-credentials -o jsonpath='{.data.password}' | base64 -d; echo
```
👀 The K8s `web-db-credentials` Secret updated on its own (now your new value).
The pod still shows the OLD env value until it restarts (env vars are injected once):
```bash
kubectl -n dev rollout restart deploy/web
kubectl -n dev exec deploy/web -- env | grep '^password='
```
👀 After the restart the pod has the new value. (Mounted-file consumers update in
place without a restart — note which behavior you chose.)

---

## What you rehearsed vs what's left for EKS
- ✅ ArgoCD installed as code (Helm, pinned) — same on EKS.
- ✅ ArgoCD manages a platform add-on as an Application — same on EKS.
- ✅ ESO `SecretStore`/`ExternalSecret` + rotation — **identical** on EKS.
- 🔜 On EKS you swap Vault → **AWS Secrets Manager** (provider block in
  `platform/secretstore.yaml`), and add **IRSA** (an IAM role bound to ESO's
  ServiceAccount — annotation in `apps/external-secrets.yaml`) so ESO authenticates
  with *no static AWS keys*. IRSA is the only piece you can't rehearse locally — the
  rest transfers 1:1.

---

## Quick rebuild-from-Git test (zero hidden state)
```bash
kubectl -n argocd delete application root dev staging prod external-secrets secrets-backend
kubectl delete ns dev staging prod external-secrets --ignore-not-found
# rebuild with the same applies as step 2:
kubectl apply -f project/demo-project.yaml -f project/platform-project.yaml
kubectl apply -f apps/root-app.yaml
# then re-supply ONLY the two manual secret inputs (step 4) and sync.
argocd app list
```
👀 All apps + namespaces come back from Git. Only the two secret *values* are re-entered.

## Cleanup
```bash
kind delete cluster --name argo-lab
```

## You can now claim
"ArgoCD installed declaratively via Helm; platform components (External Secrets
Operator) managed as ArgoCD Applications; application secrets synced from an external
backend via ExternalSecret with rotation, zero plaintext secrets in Git."
