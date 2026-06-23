# platform/ — secret backend + ESO wiring (synced by the `secrets-backend` app)

Everything here is declarative and in Git. The only values that are **not** in Git
are the secret values themselves — those live in Vault and are pulled by ESO at runtime.

Contents:
- `vault.yaml` — Vault **dev mode** pod + Service. NON-PRODUCTION (in-memory, no unseal).
- `secretstore.yaml` — ESO `SecretStore` (namespaced, `dev`) pointing at Vault.
- `externalsecret.yaml` — ESO `ExternalSecret` → creates the `web-db-credentials` Secret.

## Manual steps (the only by-hand bits — by design, no secret values in Git)

### 1. Give ESO a Vault token (out of band, never committed)
```bash
kubectl -n dev create secret generic vault-token --from-literal=token=root
```
`root` is the Vault dev-mode root token — a throwaway for the in-memory pod, not a
real credential. On EKS this Secret disappears entirely (ESO uses IRSA instead).

### 2. Write the test DB credential into Vault
```bash
# keep the value in a shell var so it never lands in a committed file:
export DB_PASS='choose-a-dev-password'
kubectl -n dev exec -it vault -- sh -c "
  export VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root
  vault kv put secret/web-db-credentials username=webuser password=$DB_PASS
"
# read it back:
kubectl -n dev exec -it vault -- sh -c '
  export VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root
  vault kv get secret/web-db-credentials
'
```

ESO then materializes the K8s Secret automatically:
```bash
kubectl -n dev get secret web-db-credentials
```

## Rotation (RUN2 step 8)
Write a new password to the **same** Vault path; within `refreshInterval` (15s) ESO
updates the K8s Secret. The web app consumes it via **env vars**, so restart the pod
to pick up the new value (`kubectl -n dev rollout restart deploy/web`).

## Note on apply order
`secrets-backend` is sync-wave **3** (after `external-secrets`, wave 1) so the
`SecretStore`/`ExternalSecret` CRDs exist before this app applies. If you apply by
hand, sync `external-secrets` first. The `vault-token` Secret (step 1) should exist
before ESO tries to authenticate — if it isn't there yet, ESO just retries until it is.
