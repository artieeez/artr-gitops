# Staging Postgres

PostgreSQL 16 for generic staging workloads. Managed by ArgoCD (`staging-postgres`).

| Item | Value |
| ---- | ----- |
| Namespace | `staging` |
| Service (in-cluster) | `postgres.staging.svc.cluster.local:5432` |
| Default database | `app` |
| User | `postgres` |
| Auth secret | `postgres-staging-auth` (SealedSecret in Git) |
| External access | Traefik NLB port **32432** (requires OCI firewall rule) |

## FBD 2026 (e-commerce assignment)

Database **`fbd2026`** holds the FBD trabalho schema (11 tables). Reload from the vault:

```bash
kubectl port-forward -n staging svc/postgres 15432:5432 &
export PGPASSWORD="$(kubectl get secret postgres-staging-auth -n staging -o jsonpath='{.data.password}' | base64 -d)"

psql -h 127.0.0.1 -p 15432 -U postgres -d fbd2026 \
  -f "disciplinas/banco de dados/Karing Becker/trabalhos/fbd-2026/entregaveis/tabelas.sql"

psql -h 127.0.0.1 -p 15432 -U postgres -d fbd2026 \
  -f "disciplinas/banco de dados/Karing Becker/trabalhos/fbd-2026/entregaveis/Instancias.sql"
```

Connection string for Part 3 (via port-forward):

```
postgresql://postgres:<password>@127.0.0.1:15432/fbd2026
```

## Local access (port-forward)

Recommended for development — no firewall changes needed:

```bash
kubectl port-forward -n staging svc/postgres 15432:5432
psql -h 127.0.0.1 -p 15432 -U postgres -d fbd2026
```

Password:

```bash
kubectl get secret postgres-staging-auth -n staging -o jsonpath='{.data.password}' | base64 -d
```

## External access (Traefik NLB)

Traefik exposes Postgres on NodePort **32432** (`IngressRouteTCP` → entrypoint `postgres1`).
Connect to `<NLB_IP>:32432` once OCI allows TCP 32432 on the Traefik NLB security list.

## Create a new database

```bash
kubectl port-forward -n staging svc/postgres 15432:5432 &
export PGPASSWORD="$(kubectl get secret postgres-staging-auth -n staging -o jsonpath='{.data.password}' | base64 -d)"
psql -h 127.0.0.1 -p 15432 -U postgres -d app -c 'CREATE DATABASE mydb;'
```

## Rotate password

```bash
NEW_PASS="$(openssl rand -base64 24 | tr -d '+/' | cut -c1-24)"
kubectl create secret generic postgres-staging-auth \
  --namespace=staging --from-literal=password="$NEW_PASS" \
  --dry-run=client -o yaml | \
  kubeseal --controller-namespace=sealed-secrets --controller-name=sealed-secrets \
  -o yaml > apps/staging/postgres/postgres-staging-auth-sealed.yaml
# commit, push, then restart the pod:
kubectl rollout restart deployment/postgres -n staging
```

See [docs/sealed-secrets.md](../../../docs/sealed-secrets.md).
