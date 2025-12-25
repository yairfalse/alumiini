#!/bin/bash
set -euo pipefail

CLUSTER_NAME="nopea-dev"

echo "==> Deleting Kind cluster '${CLUSTER_NAME}'..."
kind delete cluster --name "${CLUSTER_NAME}"

echo "==> Cleanup complete!"
