#!/usr/bin/env bash
# Build ARM64 image and push to OCIR. Run from repo root or set APP_DIR.
set -euo pipefail

APP_DIR="${APP_DIR:-$(cd "$(dirname "$0")/../../../../../ufrgs-vault/disciplinas/banco de dados/Karing Becker/trabalhos/fbd-2026/entregaveis/programa/fbd-ecommerce" 2>/dev/null && pwd)}"
REGISTRY="${REGISTRY:-sa-vinhedo-1.ocir.io}"
NS="${OCIR_NAMESPACE:-axtvnrdemzo7}"
REPO="${REPO:-fbd-ecommerce}"
TAG="${TAG:-sha-$(git -C "$APP_DIR" rev-parse --short HEAD)}"
IMAGE="${REGISTRY}/${NS}/${REPO}:${TAG}"

echo "Building ${IMAGE} (linux/arm64) from ${APP_DIR}"
docker build --platform linux/arm64 -t "$IMAGE" "$APP_DIR"
docker push "$IMAGE"
echo ""
echo "Update apps/staging/fbd-ecommerce/deployment.yaml:"
echo "  image: ${IMAGE}"
