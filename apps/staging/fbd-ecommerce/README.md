# FBD E-commerce — staging

Ruby on Rails app (Parte 3, trabalho FBD 2026) com gem `pg` (sem ActiveRecord).

| Item | Value |
| ---- | ----- |
| Namespace | `staging` |
| URL | https://fbd-staging.artr.com.br |
| Imagem | `sa-vinhedo-1.ocir.io/axtvnrdemzo7/fbd-ecommerce:<tag>` |
| PostgreSQL | `postgres.staging.svc.cluster.local:5432` / DB `fbd2026` |
| ArgoCD | `staging-fbd-ecommerce` |

## Pré-requisitos

1. **PostgreSQL** — app `staging-postgres` (já no cluster). Banco `fbd2026` com schema + VIEW — ver [postgres/README.md](../postgres/README.md).
2. **OCIR** — repositório `fbd-ecommerce` (Terraform `oracle-cluster/main.tf`).
3. **DNS** — registro `fbd-staging` → NLB `204.216.137.207` (Cloudflare).

## Build e push da imagem (ARM64)

O cluster OKE usa nós **ARM** (`VM.Standard.A1.Flex`). Build local (Apple Silicon):

```bash
APP_DIR="/path/to/ufrgs-vault/.../fbd-ecommerce"
TAG="sha-$(git -C "$APP_DIR" rev-parse --short HEAD)"
IMAGE="sa-vinhedo-1.ocir.io/axtvnrdemzo7/fbd-ecommerce:${TAG}"

docker build --platform linux/arm64 -t "$IMAGE" "$APP_DIR"
docker push "$IMAGE"
```

Login OCIR (use um **auth token** existente no Console OCI — quota máx. 2 tokens):

```bash
docker login sa-vinhedo-1.ocir.io \
  -u 'axtvnrdemzo7/<seu-usuario-oci>' \
  -p '<auth-token>'
```

Atualize o tag em `deployment.yaml` e faça commit no GitOps.

## Secrets (SealedSecrets)

| Arquivo | Conteúdo |
| ------- | -------- |
| `fbd-ecommerce-secret-sealed.yaml` | `RAILS_MASTER_KEY`, `SECRET_KEY_BASE` |
| `ocir-pull-sealed.yaml` | pull OCIR (`vcp.ocir.io` + `sa-vinhedo-1.ocir.io`) |

Senha do Postgres: reutiliza `postgres-staging-auth` (não duplicada neste app).

## Carregar SQL no banco (se necessário)

```bash
kubectl port-forward -n staging svc/postgres 15432:5432 &
export PGPASSWORD="$(kubectl get secret postgres-staging-auth -n staging -o jsonpath='{.data.password}' | base64 -d)"

psql -h 127.0.0.1 -p 15432 -U postgres -d fbd2026 -f entregaveis/tabelas.sql
psql -h 127.0.0.1 -p 15432 -U postgres -d fbd2026 -f entregaveis/Instancias.sql
psql -h 127.0.0.1 -p 15432 -U postgres -d fbd2026 -f entregaveis/consultas.sql
```

## Verificação

```bash
kubectl get pods -n staging -l app=fbd-ecommerce
kubectl logs -n staging deploy/fbd-ecommerce
curl -sI https://fbd-staging.artr.com.br/up
```

ArgoCD: `argocd app sync staging-fbd-ecommerce`
