# ArgoCD Hands-On Lab — Learn While Building

Work through each task in order. For every task:
1. Read **Context** (why it matters).
2. Try the **Challenge** yourself before scrolling.
3. Use the **Method** if you get stuck.
4. Check the **Answer** and run the **Verify** command — your output should match.

> Replace `REPLACE_ME` in every manifest with your GitHub username **before pushing**.
> Quick way: `grep -rl REPLACE_ME . | xargs sed -i 's/REPLACE_ME/YOURNAME/g'`

---

## Task 0 — Bootstrap

**Context:** ArgoCD runs *inside* your cluster and pulls from Git. You need it installed and a repo it can read.

**Method:**
```bash
# 1. create kind cluster (if not already)
kind create cluster --name argo-lab

# 2. install argocd (see extras/argocd-install.txt for full steps)
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server

# 3. push this repo to GitHub, then login with the CLI
argocd login localhost:8080 --username admin \
  --password "$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)" \
  --insecure
```

**Verify:**
```bash
argocd version --short
kubectl -n argocd get pods   # all Running
```

---

## Task 1 — App-of-Apps Pattern

**Context:** Instead of creating each Application by hand, you create ONE root Application that points at a folder of Application manifests. ArgoCD then manages your Applications *as if they were any other resource*. This is how real teams onboard dozens of apps. It is also the heart of "everything in Git."

**Challenge:** Make a single `kubectl apply` produce three child Applications (dev, staging, prod) without applying them individually.

**Method:**
```bash
# First register the project (Task 7 object) so apps have a home:
kubectl apply -f project/demo-project.yaml
# Then apply ONLY the root:
kubectl apply -f apps/root-app.yaml
```

**Answer:** `apps/root-app.yaml` has `source.path: apps` and `directory.include: '{dev.yaml,staging.yaml,prod.yaml}'`. Because it is itself an Application with automated sync, ArgoCD reads those three files and creates them. The root deliberately does NOT recurse into overlays/base.

**Verify:**
```bash
argocd app list
# EXPECT: root, dev, staging, prod  (4 apps)
kubectl -n argocd get applications
# EXPECT: same 4
```
If you only see `root`, your include glob or path is wrong.

---

## Task 2 — Kustomize Multi-Environment

**Context:** One `base/`, three thin `overlays/`. The diff between environments should be tiny and obvious (replica count + one env var). This is the single most important GitOps habit: no copy-pasted YAML per environment.

**Challenge:** Without looking, predict the replica count and `ENVIRONMENT` value for each env, then prove it with `kustomize build`.

**Method:**
```bash
kustomize build overlays/dev
kustomize build overlays/staging
kustomize build overlays/prod
```

**Answer:**
| Env | namespace | replicas | ENVIRONMENT |
|-----|-----------|----------|-------------|
| dev | dev | 1 | dev |
| staging (Kustomize variant) | staging | 2 | staging |
| prod | prod | 3 | prod |

(Staging is actually deployed via Helm — see Task 3 — but the Kustomize overlay exists so you can compare both tools.)

**Verify:**
```bash
kustomize build overlays/prod | grep -E "replicas:|namespace:|ENVIRONMENT"
# EXPECT: namespace: prod, replicas: 3, ENVIRONMENT shown as "prod"
```

---

## Task 3 — Helm Source (mixed tooling)

**Context:** Real estates mix Helm and Kustomize. ArgoCD treats both as first-class "sources." The staging Application uses the Helm `chart/` and overrides values via `spec.source.helm.parameters` — overrides live in Git (the Application manifest), not on someone's laptop.

**Challenge:** Render the chart the way ArgoCD will, with the staging overrides applied.

**Method:**
```bash
helm template web ./chart --set environment=staging --set replicaCount=2
```

**Answer:** `apps/staging.yaml` sets `helm.parameters` for `environment=staging` and `replicaCount=2`. These override `chart/values.yaml`. The rendered Deployment has `replicas: 2` and the ConfigMap has `ENVIRONMENT: "staging"`.

**Verify:**
```bash
argocd app get staging -o json | grep -A3 '"helm"'
# EXPECT to see your parameters
helm template web ./chart --set replicaCount=2 | grep replicas
# EXPECT: replicas: 2
```

---

## Task 4 — Sync Policies & Self-Heal

**Context:** Three behaviors you must be able to reason about:
- **automated** = ArgoCD syncs on Git change without you clicking.
- **selfHeal** = ArgoCD also reverts *live cluster* drift back to Git.
- **prune** = ArgoCD deletes resources removed from Git.

Dev gets all three. Staging is automated but will NOT self-heal (so you can observe drift staying). Prod is manual — nothing happens without explicit approval.

**Challenge:** Edit a dev Deployment live and predict whether ArgoCD reverts it. Do the same for staging.

**Method:**
```bash
# DEV: self-heal ON -> change is reverted within seconds
kubectl -n dev scale deploy/web --replicas=5
watch kubectl -n dev get deploy web

# STAGING: self-heal OFF -> stays changed, app shows OutOfSync but is NOT auto-fixed
kubectl -n staging scale deploy/web --replicas=9
argocd app get staging
```

**Answer:**
- Dev reverts to 1 automatically (selfHeal=true).
- Staging stays at 9 and reports `OutOfSync`; it is only corrected on the next *Git* change or a manual sync (selfHeal=false).

**Verify:**
```bash
kubectl -n dev get deploy web -o jsonpath='{.spec.replicas}'; echo   # EXPECT 1
kubectl -n staging get deploy web -o jsonpath='{.spec.replicas}'; echo # EXPECT 9
argocd app get staging | grep Sync\ Status   # EXPECT OutOfSync
```

---

## Task 5 — Sync Waves & Hooks

**Context:** Ordering. `sync-wave` orders normal resources (lower numbers first). Hooks (`PreSync`/`PostSync`) run Jobs around the sync. The ConfigMap has `sync-wave: "-1"` so it lands before the Deployment (wave 0). The PreSync Job runs a fake migration before anything syncs; PostSync runs a smoke test after.

**Challenge:** Predict the order of: PreSync migration Job, ConfigMap, Deployment, PostSync smoke test. Then watch it live.

**Method:**
```bash
# trigger a fresh sync on dev and watch resource ordering
argocd app sync dev
argocd app get dev --refresh
kubectl -n dev get jobs   # see db-migration then smoke-test
```

**Answer (execution order):**
1. **PreSync** `db-migration` Job runs to completion.
2. Wave **-1**: `web-config` ConfigMap applied.
3. Wave **0**: `web` Deployment + Service applied.
4. **PostSync** `smoke-test` Job runs after healthy.

Both hook Jobs auto-delete on success (`hook-delete-policy: HookSucceeded`).

**Verify:**
```bash
argocd app get dev | grep -E "Hook|Synced"
# During sync you'll see db-migration (PreSync) then smoke-test (PostSync)
```

---

## Task 6 — Sync Windows

**Context:** Sync windows block (or allow) syncs on a schedule, set on the **AppProject**. Useful for change freezes. The lab project denies automated prod syncs during a daily 1-hour window but still allows *manual* sync (`manualSync: true`).

**Challenge:** Inspect the active windows and reason about whether prod could auto-sync right now.

**Method:**
```bash
argocd proj windows list demo-project
```

**Answer:** `project/demo-project.yaml` has a `deny` window (`schedule: '0 0 * * *'`, `duration: 1h`) scoped to `applications: [prod]` with `manualSync: true`. During that window automated sync is blocked; you can still sync prod by hand. (Prod is manual anyway — this teaches the mechanism cleanly. To see a *blocking* effect, temporarily widen the schedule to the current time.)

**Verify:**
```bash
argocd proj windows list demo-project
# EXPECT a deny window listed, applications: prod, manualSync: Enabled
```

---

## Task 7 — AppProjects & RBAC

**Context:** An AppProject is a guardrail: which repos may be used, which namespaces/clusters apps may deploy to, and which resource kinds are allowed. This is how you stop an app from, say, creating a ClusterRole or deploying to `kube-system`.

**Challenge:** Try to make an Application that violates the project (e.g., deploy to `default`) and predict the result.

**Method:**
```bash
# temporarily point apps/dev.yaml destination.namespace to "default" and sync:
argocd app set dev --dest-namespace default
argocd app sync dev
# observe the error, then revert
argocd app set dev --dest-namespace dev
```

**Answer:** `project/demo-project.yaml` whitelists only your repo, only the `dev/staging/prod/argocd` namespaces, only `Namespace` as a cluster resource, and a short list of namespaced kinds (ConfigMap, Service, Deployment, Job, HPA). Deploying to `default` is rejected with a message like `application destination ... is not permitted in project demo-project`.

**Verify:**
```bash
argocd proj get demo-project
# EXPECT destinations limited to dev/staging/prod/argocd and the kind whitelists shown
```

---

## Task 8 — Drift & Diff

**Context:** ArgoCD continuously compares live state to desired (Git). Because **prod is manual**, drift will sit as `OutOfSync` until you approve — exactly the controlled behavior you want in production.

**Challenge:** Cause prod drift and view the diff three ways: CLI diff, `app get`, and UI.

**Method:**
```bash
# first do an initial manual sync so prod exists
argocd app sync prod
# now drift it
kubectl -n prod scale deploy/web --replicas=7
argocd app diff prod
argocd app get prod
```

**Answer:** `argocd app diff prod` prints a red/green diff showing live `replicas: 7` vs desired `replicas: 3`. `app get` shows `OutOfSync`. Nothing auto-corrects (no automated policy). You fix it with `argocd app sync prod`.

**Verify:**
```bash
argocd app diff prod   # EXPECT a non-empty diff on replicas
argocd app get prod | grep Sync\ Status   # EXPECT OutOfSync
```

---

## Task 9 — Health & Degraded Status

**Context:** ArgoCD has built-in health assessment per resource kind. A Deployment whose pods can't pull their image becomes **Degraded**. Knowing how to read health vs sync status is a core debugging skill (an app can be Synced but Degraded).

**Challenge:** Make dev Degraded *while staying Synced*, then explain the difference between Sync status and Health status.

**Method:**
```bash
# add the bad image to overlays/dev/replica-patch.yaml (see extras/broken-image-patch.yaml)
# commit + push, dev auto-syncs
argocd app get dev
kubectl -n dev get pods   # ImagePullBackOff
# then revert the commit
```

**Answer:** After pushing `image: nginx:doesnotexist-9.9.9`, dev becomes **Synced** (live matches Git) but **Degraded** (pods fail to pull). This proves Sync ≠ Health: Sync = "does the cluster match Git?", Health = "is the running thing actually OK?".

**Verify:**
```bash
argocd app get dev | grep -E "Sync Status|Health Status"
# EXPECT: Sync Status: Synced, Health Status: Degraded
```
Revert the commit; dev returns to Healthy.

---

## Task 10 — Rollback

**Context:** ArgoCD keeps a history of synced revisions. You can roll the *live cluster* back to a previous synced revision without reverting Git — useful for an emergency while you sort out the Git fix.

**Challenge:** Break dev with a bad commit, sync it, then roll back to the prior good revision using history (not `git revert`).

**Method:**
```bash
argocd app history dev          # note the IDs
argocd app rollback dev <ID>    # roll live cluster to a previous good revision
```

**Answer:** `argocd app history dev` lists revisions with IDs and Git SHAs. `argocd app rollback dev <ID>` redeploys that revision. Note: with automated+selfHeal, ArgoCD may re-sync to Git HEAD; for a real rollback you either disable auto-sync first (`argocd app set dev --sync-policy none`) or fix Git. This teaches *why* Git remains the source of truth.

**Verify:**
```bash
argocd app history dev   # EXPECT multiple rows
# after rollback, the live pods run the older image/replica count
```

---

## Task 11 — Notifications (optional)

**Context:** `argocd-notifications` (now bundled) sends events (sync failed, health degraded) to Slack/webhook/email via triggers + templates configured in a ConfigMap. Wiring one trigger teaches the trigger→template→service flow.

**Challenge:** Configure a `on-sync-failed` trigger to a webhook and force a failure.

**Method:**
```bash
# minimal: patch argocd-notifications-cm with a webhook service + subscription annotation on an app
kubectl -n argocd edit cm argocd-notifications-cm
# add a service.webhook.<name>, a template, and a trigger; then annotate the app:
argocd app set dev --label notify=yes   # or add notifications.argoproj.io/subscribe annotation
```

**Answer:** You add three things to `argocd-notifications-cm`: a `service.webhook.X`, a `template.app-sync-failed`, and a `trigger.on-sync-failed`. Then subscribe the app via annotation `notifications.argoproj.io/subscribe.on-sync-failed.X: ""`. Forcing a sync failure (e.g., bad manifest) fires the webhook. This task is optional and provider-specific, so verification is "did the webhook receive a POST."

**Verify:** Trigger a failure and watch your webhook endpoint / Slack channel receive the event.

---

## Task 12 — CLI + Declarative Parity (the anti-debt rule)

**Context:** The whole point of GitOps: anything ArgoCD knows should be reconstructable from Git. If you click-create something in the UI that isn't in a committed manifest, you've created hidden state — technical debt.

**Challenge:** Delete EVERYTHING and rebuild from Git alone. If it comes back identical, you passed.

**Method:**
```bash
# nuke the apps (finalizers cascade-delete the workloads)
kubectl -n argocd delete application root dev staging prod
kubectl delete ns dev staging prod --ignore-not-found

# rebuild from Git with two applies:
kubectl apply -f project/demo-project.yaml
kubectl apply -f apps/root-app.yaml
```

**Answer:** Because every Application, the project, and all workloads are defined in committed YAML, two `kubectl apply`s fully reconstruct the system. You never ran an `argocd app create` that wasn't backed by a file. That is the parity guarantee — and your guardrail against technical debt.

**Verify:**
```bash
argocd app list   # EXPECT root, dev, staging, prod return on their own
kubectl get ns dev staging prod   # EXPECT all three recreated
```

---

## Feature coverage checklist

- [ ] App-of-Apps (Task 1)
- [ ] Kustomize base+overlays (Task 2)
- [ ] Helm source + parameter overrides (Task 3)
- [ ] automated / selfHeal / prune (Task 4)
- [ ] manual sync / approval gate (Task 4, 8)
- [ ] sync waves (Task 5)
- [ ] PreSync / PostSync hooks (Task 5)
- [ ] sync windows (Task 6)
- [ ] AppProject guardrails / RBAC (Task 7)
- [ ] drift detection + diff (Task 8)
- [ ] health vs sync status (Task 9)
- [ ] rollback + history (Task 10)
- [ ] notifications (Task 11)
- [ ] declarative parity / rebuild-from-Git (Task 12)

## Anti-technical-debt rules you practiced
1. Everything in Git; CLI used only to inspect/sync/rollback, never to create unbacked state.
2. One AppProject; no deploying to `default`.
3. Pinned image and chart versions (no `latest`).
4. Validate locally (`kustomize build`, `helm template`) before committing.
5. Prove parity by rebuilding from Git (Task 12).
