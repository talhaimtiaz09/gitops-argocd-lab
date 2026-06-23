# eks/ — EKS entry point (consume this from your EKS infra repo)

This is the AWS-flavored counterpart of the kind lab. It is the **app-of-apps root +
External Secrets Operator (IRSA) + AWS Secrets Manager wiring + sample `web` workload**
for a real EKS cluster. Your `eks-paved-road` (Terraform) repo references this path —
it does **not** copy these files.

```
eks/
├── apps/
│   ├── root-app.yaml                 # app-of-apps root (apply this once)
│   ├── external-secrets-operator.yaml # ESO via Helm, IRSA-annotated   (wave 1)
│   ├── secrets.yaml                  # -> eks/secrets path             (wave 2)
│   └── web.yaml                      # -> overlays/eks (web workload)  (wave 3)
└── secrets/
    ├── aws-secret-store.yaml         # ESO SecretStore -> AWS Secrets Manager
    └── web-db-external-secret.yaml   # materializes web-db-credentials
```

## Values you must set (3 of them — all env-specific, none are secret values)

| Placeholder | Where | Source |
|---|---|---|
| `REPLACE_ME_ESO_IRSA_ROLE_ARN` | `apps/external-secrets-operator.yaml` | Terraform output: ESO IRSA role ARN |
| `REPLACE_ME_AWS_REGION` | `secrets/aws-secret-store.yaml` | your region, e.g. `us-east-1` |
| `REPLACE_ME_SECRET_NAME` | `secrets/web-db-external-secret.yaml` | the AWS Secrets Manager secret name |

The **secret value itself never lives here** — it stays in AWS Secrets Manager. Store it
as JSON: `{"username":"webuser","password":"<set-in-aws>"}`.

### How to inject the values (pick one)
- **Kustomize overlay in your EKS repo (recommended, keeps this repo generic):** add a
  tiny overlay that pulls this repo as a remote base and patches the three values:
  ```yaml
  # eks-paved-road/gitops/eks-dev/kustomization.yaml
  resources:
    - github.com/talhaimtiaz09/argocd-gitops-config//eks/secrets?ref=main
  # then patch region + secret name here
  ```
- **ArgoCD Application parameters:** override the Helm param (`serviceAccount.annotations…`)
  and use Kustomize `replacements` from the root Application your Terraform applies.
- **Terraform `templatefile`/sed** during bootstrap (simplest, least GitOps-pure).

## Apply order (your EKS bootstrap does this after the cluster is up)
```bash
kubectl apply -f project/eks-project.yaml      # the AppProject
kubectl apply -f eks/apps/root-app.yaml        # app-of-apps -> ESO -> secrets -> web
```
Sync-waves guarantee: **ESO (1) → SecretStore/ExternalSecret (2) → web (3)**.

## Prereqs on the cluster side (owned by the Terraform repo, not here)
- EKS **OIDC provider** enabled.
- IAM role for the ESO ServiceAccount (least-privilege `secretsmanager:GetSecretValue`
  on the app secret), trust policy bound to the OIDC provider → its ARN is
  `REPLACE_ME_ESO_IRSA_ROLE_ARN`.
- The Secrets Manager secret created (value out-of-band, never in Git/state).

## What's identical to the kind lab (and why this is a safe rehearsal)
The `ExternalSecret`, the app-of-apps pattern, sync-waves, and the `envFrom` consumption
in `overlays/eks` are the **same** as the kind lab. Only two things change for AWS:
the SecretStore provider (`vault` → `aws`) and auth (Vault token → IRSA). See
`docs/architecture.md` for the full swap diagram.
