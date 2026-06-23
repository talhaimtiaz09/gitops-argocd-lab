# eks-paved-road — Execution Checklist (Fast & Low-Cost)

Source of truth for execution. Build in long focused sessions. **Destroy the cluster at every session end.** Record **one** demo at the very end; everything else is documented in text + screenshots.

---

## Cost Rules (read every session)

- [ ] EKS control plane = ~$0.10/hr and is NOT free-tier. Cluster exists ONLY while actively working.
- [ ] `terraform destroy` at the end of EVERY session that created a cluster.
- [ ] Never use `type: LoadBalancer`. Use `kubectl port-forward` for ALL UI access (ArgoCD, Grafana).
- [ ] After every destroy, sweep AWS console for orphans: NAT gateways, Elastic IPs, EBS volumes, ELBs, unattached ENIs, RDS snapshots.
- [ ] State backend (S3 + DynamoDB) is the ONLY stack left running permanently — it costs pennies.
- [ ] Use spot `t3.small` nodes for Phases 2–3 (core). Bump to `t3.medium` only during observability.
- [ ] Postgres runs as an in-cluster pod. NEVER use RDS.

## Global Definition of Done (per phase)

- [ ] Changes committed to Git with meaningful message (author `talha.imtiaz.dev@gmail.com`).
- [ ] README updated with a one-paragraph note for the completed phase.
- [ ] Screenshots saved under `docs/`.
- [ ] No plaintext secrets, kubeconfigs, state files, or plans committed.
- [ ] Cluster destroyed cleanly + orphan sweep done (if session created a cluster).

---

## PHASE 1 — Foundation (free, no cluster, build once)

> Goal: every safety rail and the permanent state backend in place BEFORE any EKS dollar is spent.

### Account & Cost Controls
- [x] Enable MFA on AWS root account.
- [x] Configure AWS Budget alert at `$5/month` → `talha.imtiaz.dev@gmail.com`.
- [ ] Create a non-root IAM admin identity for daily work.
- [ ] Use that IAM identity (not root) from here on.
- [ ] Pick and document region: `us-east-1`.
- [ ] Define project tag set: `Project=eks-paved-road`, `Owner=talhaimtiaz09`, `Environment=dev`, `ManagedBy=terraform`.

### Local Toolchain
- [ ] Install + verify `terraform`, `aws`, `kubectl`, `helm`.
- [ ] Install `eksctl` (inspection only) and optionally `k9s`.
- [ ] Configure a named AWS profile.
- [ ] Verify: `aws sts get-caller-identity --profile <profile>`.

### Repo + State Backend
- [ ] Keep repo private until first safe public-ready pass.
- [ ] `.gitignore` excludes state, credentials, kubeconfigs, logs, build artifacts, `*.tfplan`.
- [ ] Add first architecture sketch under `docs/diagrams/`.
- [ ] Create Terraform backend bootstrap: S3 state bucket + DynamoDB lock table.
- [ ] Enable S3 versioning + server-side encryption; block public access on bucket.
- [ ] Apply backend bootstrap ONCE. Leave it running permanently.
- [ ] Document backend names + region in README.
- [ ] Commit scaffold.

**Phase 1 done when:** clean clone shows intended layout, budget + MFA + IAM admin live, state backend applied. No cluster touched yet.

---

## PHASE 2 — Core Cluster + GitOps + Secrets (the heart, one apply)

> Goal: a self-healing GitOps cluster running a real app with zero static keys. ~60% of portfolio value. Do in one or two long sessions.

### Terraform Structure
- [ ] `terraform/envs/dev` as deployable root module.
- [ ] `terraform/modules/vpc` — VPC, public + private subnets, route tables, ONE NAT gateway, tags.
- [ ] `terraform/modules/eks` — wrap official `terraform-aws-modules/eks/aws`.
- [ ] Providers pinned to explicit versions.
- [ ] Variables with descriptions + safe defaults; outputs for cluster name, region, kubeconfig cmd, VPC ids.
- [ ] Enable EKS OIDC provider (needed for IRSA below).
- [ ] `terraform fmt -recursive` + `terraform validate`.

### Cluster Bring-Up
- [ ] Spot managed node group: 1–2 × `t3.small`.
- [ ] Configure cluster access for deploying IAM identity.
- [ ] `aws eks update-kubeconfig` → verify `kubectl get nodes` Ready.
- [ ] **Time this apply-from-zero and record the number** (this is your DR rebuild metric — no separate milestone needed).

### GitOps (ArgoCD)
- [ ] Install ArgoCD via Helm (Terraform or documented bootstrap script).
- [ ] Access via port-forward only. Document why public exposure is avoided.
- [ ] Add `gitops/` structure for platform apps + sample app manifests.
- [ ] Create ArgoCD `Application` watching this repo's GitOps path.
- [ ] Deploy sample app: API + in-cluster Postgres pod.
- [ ] Test auto-sync: push a manifest change → confirm ArgoCD applies it.
- [ ] Test self-heal: delete a synced resource → confirm ArgoCD restores it.

### Secrets + IRSA (fold in here)
- [ ] Create IAM roles for service accounts (IRSA), least privilege.
- [ ] Install External Secrets Operator (as an ArgoCD app).
- [ ] Store app DB credentials in AWS Secrets Manager.
- [ ] Sync into Kubernetes via `ExternalSecret`.
- [ ] Prove pods contain NO static AWS keys.
- [ ] Rotate secret in Secrets Manager → confirm K8s secret updates.

**Phase 2 done when:** ArgoCD auto-syncs + self-heals a real app, secrets pulled from Secrets Manager with no static keys. Document GitOps flow + security posture (IRSA, ESO) in README. Destroy at session end.

---

## PHASE 3 — Observability + Autoscaling (heavier, own session)

> Goal: the memory-hungry layer. Bump nodes to `t3.medium`, build, screenshot, tear down promptly.

### Observability
- [ ] Scale node group to `t3.medium` for this phase.
- [ ] Install `kube-prometheus-stack` (as ArgoCD app).
- [ ] Install Loki for logs.
- [ ] Verify Grafana cluster dashboards: node CPU, memory, pod health.
- [ ] Build/import app dashboard: request rate, latency, error rate.
- [ ] Configure one meaningful alert (crash loop or high error rate).
- [ ] Trigger the alert intentionally; save dashboard + alert screenshots under `docs/`.

### Karpenter Autoscaling + FinOps
- [ ] Install Karpenter (Terraform or GitOps) + configure its IAM permissions.
- [ ] Create NodePool supporting spot + on-demand; enable consolidation.
- [ ] Deploy a workload needing extra capacity → confirm Karpenter provisions nodes fast.
- [ ] Remove workload → confirm consolidation/removal.
- [ ] Record before/after node count + cost implication (text + screenshots).

**Phase 3 done when:** Grafana shows dashboards + a fired alert, Karpenter scales up and consolidates down. Document observability + FinOps in README. Destroy at session end.

---

## PHASE 4 — CI/CD Gates + Docs + Final Demo

> Goal: free, cluster-less security gates, then all docs, then the single demo recording.

### DevSecOps (all free, runs on GitHub runners — no AWS)
- [ ] GitHub Actions workflow: `terraform fmt` + `validate`.
- [ ] Add Checkov or tfsec for Terraform; fail CI on critical findings.
- [ ] Add Trivy image scan for sample app; fail CI on critical CVEs.
- [ ] Introduce a blocked finding in a short-lived branch → capture failed CI evidence.
- [ ] Fix → capture passing CI evidence.
- [ ] Document security gates in README.

### Docs (offline, no cluster)
- [ ] `docs/runbooks/disaster-recovery.md` (include your timed rebuild number from Phase 2).
- [ ] `docs/runbooks/app-alert-incident.md`.
- [ ] Finalize architecture diagram near top of README.
- [ ] README covers: problem, platform value, architecture, layers, security, autoscaling, cost, observability, DR, reproduction, teardown, trade-offs.
- [ ] Write portfolio case study + four resume bullets.

### The ONE Demo (only cluster spin-up in this phase)
- [ ] Fresh `terraform apply` from zero.
- [ ] Record one continuous 4–6 min take:
  - apply → nodes Ready
  - ArgoCD syncing the app → self-heal (delete resource, watch return)
  - secret pulled from Secrets Manager, no static keys
  - Grafana dashboard + alert firing
  - Karpenter scale-up under load → consolidate down
  - CI run: blocked finding → then passing
- [ ] Save clip under `docs/`.
- [ ] Destroy + final orphan sweep.

### Wrap-Up
- [ ] Pin repo on GitHub.
- [ ] Make repo public (after safety pass).
- [ ] Update portfolio Services section to reference this repo as Terraform/IaC proof.

---

## Phase Order Summary

| Phase | Cluster? | Cost | Notes |
|-------|----------|------|-------|
| 1 Foundation | No | ~$0 | Backend left running (pennies) |
| 2 Core + GitOps + Secrets | Yes (`t3.small` spot) | low | 60% of value; time the apply |
| 3 Observability + Karpenter | Yes (`t3.medium` spot) | medium | Heaviest; short session |
| 4 CI + Docs + Demo | Only for demo | ~$0 until demo | CI is free on GitHub |

**Estimated total AWS cost with discipline: ~$4–7.**