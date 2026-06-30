# Staging Postgres

PostgreSQL 16 for generic staging workloads. Managed by ArgoCD (`staging-postgres`).

| Item | Value |
| ---- | ----- |
| Namespace | `staging` |
| Service (in-cluster) | `postgres.staging.svc.cluster.local:5432` |
| Default database | `app` |
| User | `postgres` |
| Auth secret | `postgres-staging-auth` (SealedSecret in Git) |
| External access | **None** — cluster-internal + `kubectl port-forward` only |

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

Connection string in-cluster (Rails deployment):

```
DB_HOST=postgres.staging.svc.cluster.local
DB_NAME=fbd2026
```

App URL (after DNS): https://fbd-staging.artr.com.br — ArgoCD app `staging-fbd-ecommerce`.

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

## Create a new database

```bash
kubectl port-forward -n staging svc/postgres 15432:5432 &
export PGPASSWORD="$(kubectl get secret postgres-staging-auth -n staging -o jsonpath='{.data.password}' | base64 -d)"
psql -h 127.0.0.1 -p 15432 -U postgres -d app -c 'CREATE DATABASE mydb;'
```

## Rotate password

`POSTGRES_PASSWORD` só vale na **primeira** inicialização do volume. Depois de alterar o SealedSecret, é preciso atualizar o role no banco:

```bash
NEW_PASS="$(openssl rand -base64 24 | tr -d '+/' | cut -c1-24)"
kubectl create secret generic postgres-staging-auth \
  --namespace=staging --from-literal=password="$NEW_PASS" \
  --dry-run=client -o yaml | \
  kubeseal --controller-namespace=sealed-secrets --controller-name=sealed-secrets \
  -o yaml > apps/staging/postgres/postgres-staging-auth-sealed.yaml
# commit, push, aguardar sync do SealedSecret, depois:
kubectl exec -n staging deploy/postgres -- psql -U postgres \
  -c "ALTER USER postgres WITH PASSWORD '$NEW_PASS';"
kubectl rollout restart deployment/fbd-ecommerce -n staging   # se houver apps usando o secret
```

## Troubleshooting: `password authentication failed` (apps in-cluster)

Conexões **dentro do pod** Postgres usam `trust` (socket/127.0.0.1). Apps em outros pods usam TCP + SCRAM e exigem a senha real do role — que pode divergir do Secret se o volume foi criado antes do secret atual.

Sincronizar senha do role com o Secret (sem reiniciar o Postgres):

```bash
PASS="$(kubectl get secret postgres-staging-auth -n staging -o jsonpath='{.data.password}' | base64 -d)"
kubectl exec -n staging deploy/postgres -- psql -U postgres \
  -c "ALTER USER postgres WITH PASSWORD '$PASS';"
```

Validar de outro pod:

```bash
kubectl exec -n staging deploy/postgres -- sh -c \
  "PGPASSWORD=\"$PASS\" psql -h postgres.staging.svc.cluster.local -U postgres -d fbd2026 -c 'SELECT 1'"
```

See [docs/sealed-secrets.md](../../../docs/sealed-secrets.md).
