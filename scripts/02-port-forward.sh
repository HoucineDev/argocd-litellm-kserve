#!/usr/bin/env bash
# scripts/02-port-forward.sh
# Bash/WSL equivalent of 02-port-forward.ps1
set -euo pipefail

echo "==> Waiting for ArgoCD server..."
kubectl -n argocd wait --for=condition=available --timeout=300s deployment/argocd-server

echo "==> Waiting for LiteLLM deployment to appear (up to 5 min)..."
deadline=$(($(date +%s) + 300))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if kubectl -n litellm get deployment -l app.kubernetes.io/name=litellm 2>/dev/null | grep -q litellm; then
    break
  fi
  sleep 10
done
kubectl -n litellm wait --for=condition=available --timeout=600s deployment \
  -l app.kubernetes.io/name=litellm

echo ""
echo "==> Starting port-forwards (Ctrl-C to stop)..."
echo "    ArgoCD:  http://localhost:8080"
echo "    LiteLLM: http://localhost:4000  (master key: sk-litellm-local-dev-key)"
echo ""

# Trap to clean up child processes
cleanup() {
  echo ""
  echo "Stopping port-forwards..."
  kill $(jobs -p) 2>/dev/null || true
}
trap cleanup EXIT INT TERM

kubectl -n argocd port-forward svc/argocd-server 8080:80 &
kubectl -n litellm port-forward svc/litellm 4000:4000 &

wait
