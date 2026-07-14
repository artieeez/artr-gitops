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

Currently scaled to **0 replicas** (CPU headroom). PVC data is retained.

## Local access (port-forward)

Recommended for development — no firewall changes needed:

```bash
kubectl port-forward -n staging svc/postgres 15432:5432
psql -h 127.0.0.1 -p 15432 -U postgres -d app
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
# commit, push, aguardar sync do SealedSecret, depois (with replicas > 0):
kubectl exec -n staging deploy/postgres -- psql -U postgres \
  -c "ALTER USER postgres WITH PASSWORD '$NEW_PASS';"
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
  "PGPASSWORD=\"$PASS\" psql -h postgres.staging.svc.cluster.local -U postgres -d app -c 'SELECT 1'"
```

See [docs/sealed-secrets.md](../../../docs/sealed-secrets.md).
