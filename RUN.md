# ArgoCD Speed Run — Follow Along

Just run each block top to bottom. After each, glance at **👀 you should see** and keep moving.
Total time: ~60–90 min. Everything is in Git; nothing is created by hand.

> One-time: replace the repo placeholder, then push this repo to GitHub.
> ```bash
> grep -rl REPLACE_ME . | xargs sed -i 's/REPLACE_ME/YOURNAME/g'
> git add . && git commit -m "init" && git push
> ```

---

## 0 · Install (one time)
```bash
kind create cluster --name argo-lab
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server

# login
argocd login localhost:8080 --username admin \
  --password "$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)" \
  --insecure &   # keep this port-forward running in another terminal:
kubectl -n argocd port-forward svc/argocd-server 8080:443
```
👀 `argocd version --short` prints client + server versions.

---

## 1 · Deploy everything from Git (App-of-Apps)
```bash
kubectl apply -f project/demo-project.yaml
kubectl apply -f apps/root-app.yaml
argocd app list
```
👀 Four apps appear: **root, dev, staging, prod**. The root created the other three.
*(That's the app-of-apps pattern: one apply → many apps.)*

---

## 2 · Watch the environments sync
```bash
argocd app get dev
kubectl -n dev get deploy,po
kubectl -n staging get deploy
```
👀 dev = 1 replica (Kustomize), staging = 2 replicas (Helm). Both **Synced + Healthy**.
*(dev uses overlays/dev, staging uses the Helm chart/ — two config tools, one tool to rule them.)*

---

## 3 · Prod is manual — see the gate
```bash
argocd app get prod
argocd app sync prod          # you must approve prod explicitly
kubectl -n prod get deploy
```
👀 Before sync: prod is **OutOfSync**. After: 3 replicas, Healthy.
*(dev/staging auto-sync; prod waits for you. That's your production safety gate.)*

---

## 4 · Self-heal in action
```bash
kubectl -n dev scale deploy/web --replicas=5
sleep 8
kubectl -n dev get deploy web
```
👀 Replicas snap back to **1**. ArgoCD reverted your live change (selfHeal=true on dev).
```bash
kubectl -n staging scale deploy/web --replicas=9
sleep 8
kubectl -n staging get deploy web      # stays 9
argocd app get staging | grep Sync
```
👀 staging stays **9** and shows **OutOfSync** — selfHeal is off there, so drift sits.

---

## 5 · Sync waves + hooks (ordering)
```bash
argocd app sync dev
argocd app get dev | grep -iE "hook|wave|migration|smoke"
kubectl -n dev get jobs
```
👀 Order: **PreSync** db-migration Job → ConfigMap (wave -1) → Deployment (wave 0) → **PostSync** smoke-test Job. Hook Jobs auto-delete on success.

---

## 6 · Drift + diff on prod
```bash
kubectl -n prod scale deploy/web --replicas=7
argocd app diff prod
argocd app get prod | grep Sync
```
👀 `diff` shows red/green **7 vs 3**; prod stays **OutOfSync** (manual, won't auto-fix).
```bash
argocd app sync prod          # fix it
```
👀 Back to 3, Synced.

---

## 7 · Health vs Sync (break it on purpose)
```bash
# point dev at a bad image, commit, push
sed -i 's#nginx:1.27.0#nginx:doesnotexist-9.9.9#' base/deployment.yaml
git commit -am "break image" && git push
argocd app sync dev
sleep 10
argocd app get dev | grep -E "Sync Status|Health Status"
kubectl -n dev get po
```
👀 **Synced** (matches Git) but **Degraded** (ImagePullBackOff). Sync ≠ Health.
```bash
# revert
git revert --no-edit HEAD && git push
argocd app sync dev
```
👀 dev returns to **Healthy**.

---

## 8 · Rollback (live cluster, not Git)
```bash
argocd app set dev --sync-policy none      # stop auto-sync so rollback sticks
argocd app history dev
argocd app rollback dev <ID-from-history>
```
👀 dev redeploys an older revision. Re-enable later: `argocd app set dev --sync-policy automated`.

---

## 9 · Guardrails (AppProject)
```bash
argocd proj get demo-project
argocd app set dev --dest-namespace default && argocd app sync dev    # should FAIL
argocd app set dev --dest-namespace dev                                # revert
```
👀 The project blocks deploying to `default` — only dev/staging/prod/argocd are allowed.

---

## 10 · Sync window
```bash
argocd proj windows list demo-project
```
👀 A **deny** window scoped to prod is listed (manualSync allowed). That's change-freeze control.

---

## 11 · Prove zero technical debt (rebuild from Git)
```bash
kubectl -n argocd delete application root dev staging prod
kubectl delete ns dev staging prod --ignore-not-found
# rebuild with the same two commands as step 1:
kubectl apply -f project/demo-project.yaml
kubectl apply -f apps/root-app.yaml
argocd app list
```
👀 All four apps + all namespaces come back identically. Everything lived in Git. ✅

---

## Done — you touched:
app-of-apps · Kustomize · Helm · auto-sync · self-heal · prune · manual gate · sync waves · hooks · drift/diff · health-vs-sync · rollback · AppProject guardrails · sync windows · declarative rebuild.

## Cleanup
```bash
kind delete cluster --name argo-lab
```
