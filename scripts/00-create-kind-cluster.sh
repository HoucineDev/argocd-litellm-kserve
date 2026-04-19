#!/usr/bin/env bash
# scripts/00-create-kind-cluster.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Checking prerequisites..."
for cmd in docker kind kubectl helm; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd not found"; exit 1; }
done
docker info >/dev/null 2>&1 || { echo "ERROR: Docker not running"; exit 1; }

echo "==> Creating kind cluster 'llm-platform'..."
if kind get clusters 2>/dev/null | grep -q '^llm-platform$'; then
  echo "Cluster already exists. Delete with: kind delete cluster --name llm-platform"
  exit 0
fi

kind create cluster --config "$SCRIPT_DIR/kind-config.yaml"

echo "==> Waiting for node to be Ready..."
kubectl wait --for=condition=Ready node --all --timeout=120s

kubectl cluster-info --context kind-llm-platform
kubectl get nodes -o wide

echo ""
echo "Cluster ready. Next: bash scripts/01-bootstrap.sh"
