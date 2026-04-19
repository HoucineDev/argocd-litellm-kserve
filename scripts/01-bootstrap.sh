#!/usr/bin/env bash
# scripts/01-bootstrap.sh
#
# Installs ArgoCD into the cluster (via Helm — this is the only non-GitOps step;
# from here on, ArgoCD manages everything including itself if you want).
# Then applies the root App-of-Apps so ArgoCD starts reconciling the stack.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Sanity check
kubectl config current-context | grep -q 'kind-llm-platform' || {
  echo "ERROR: Current kubectl context is not kind-llm-platform."
  echo "Switch with: kubectl config use-context kind-llm-platform"
  exit 1
}

echo "==> Adding ArgoCD Helm repo..."
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update argo

echo "==> Installing ArgoCD into argocd namespace..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --values "$REPO_ROOT/bootstrap/values-argocd.yaml" \
  --wait --timeout 10m

echo "==> ArgoCD installed. Admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
echo ""

echo ""
echo "==> Applying root App-of-Apps..."
# NOTE: edit apps/root-app.yaml and set repoURL to your Git remote before this
# will actually pull anything. For local-only iteration, you can kubectl apply
# the individual Application manifests using 'directory' source pointing at
# local paths — but that's not true GitOps. Push to GitHub first.
kubectl apply -f "$REPO_ROOT/apps/root-app.yaml"

echo ""
echo "Done. Next:"
echo "  1. Start port-forwards:   ./scripts/02-port-forward.ps1  (or -forward.sh)"
echo "  2. ArgoCD UI:             http://localhost:8080   (user: admin, pw above)"
echo "  3. Watch apps sync:       kubectl -n argocd get applications -w"
