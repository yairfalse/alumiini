#!/bin/bash
set -euo pipefail

CLUSTER_NAME="nopea-dev"
IMAGE_NAME="nopea:dev"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

echo "==> Building Docker image..."
docker build -t "${IMAGE_NAME}" .

echo "==> Loading image into Kind..."
kind load docker-image "${IMAGE_NAME}" --name "${CLUSTER_NAME}"

echo "==> Restarting deployment..."
kubectl -n nopea-system rollout restart deployment/nopea-controller

echo "==> Waiting for rollout..."
kubectl -n nopea-system rollout status deployment/nopea-controller

echo ""
echo "==> Reload complete!"
kubectl -n nopea-system get pods
