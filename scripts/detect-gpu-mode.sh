#!/usr/bin/env bash
# scripts/detect-gpu-mode.sh
#
# Detects whether the cluster has usable GPUs and updates
# apps/model-serving.yaml to point at the right values overlay.
#
# Logic:
#   1. Check if any node advertises nvidia.com/gpu capacity
#   2. If yes, try scheduling a tiny CUDA probe pod
#   3. If probe succeeds  → use values-gpu.yaml
#      If probe fails     → use values-cpu.yaml (fallback)
#      If no GPU node     → use values-cpu.yaml
#
# Run this AFTER `01-bootstrap.sh` but BEFORE pushing to Git
# (or re-run if your cluster's GPU situation changes).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_FILE="$REPO_ROOT/apps/model-serving.yaml"

echo "==> Detecting GPU availability on cluster..."

# Step 1: does any node advertise the GPU resource?
gpu_capacity=$(kubectl get nodes -o json | jq -r '
  [.items[].status.capacity["nvidia.com/gpu"] // "0"] | map(tonumber) | add
')

if [ "$gpu_capacity" = "0" ] || [ -z "$gpu_capacity" ]; then
  echo "  No nvidia.com/gpu capacity on any node."
  MODE="cpu"
else
  echo "  Found $gpu_capacity GPU(s) advertised. Running probe pod..."

  # Step 2: actually try to run something on the GPU. This catches the
  # common WSL2+kind case where nvidia.com/gpu is advertised but NVML
  # can't load inside the pod.
  kubectl delete pod gpu-probe -n default --ignore-not-found >/dev/null 2>&1 || true
  cat <<'EOF' | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: gpu-probe
  namespace: default
spec:
  restartPolicy: Never
  containers:
    - name: cuda-sample
      image: nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda11.7.1
      resources:
        limits:
          nvidia.com/gpu: 1
EOF

  # Wait up to 90s for completion
  if kubectl wait --for=condition=Ready pod/gpu-probe --timeout=90s >/dev/null 2>&1 \
     || kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/gpu-probe --timeout=90s >/dev/null 2>&1; then
    # Read the logs to confirm CUDA actually ran
    logs=$(kubectl logs gpu-probe 2>&1 || true)
    if echo "$logs" | grep -qi "Test PASSED\|Result = PASS"; then
      echo "  GPU probe SUCCEEDED."
      MODE="gpu"
    else
      echo "  GPU probe ran but didn't report success. Logs:"
      echo "$logs" | sed 's/^/    /'
      echo "  Falling back to CPU."
      MODE="cpu"
    fi
  else
    echo "  GPU probe TIMED OUT or FAILED. Likely cause on WSL2+kind:"
    echo "    - NVML library not propagated into kind node"
    echo "    - nvidia-container-toolkit not registered as RuntimeClass"
    echo "  See docs/TROUBLESHOOTING.md"
    kubectl describe pod gpu-probe 2>&1 | tail -20 | sed 's/^/    /'
    MODE="cpu"
  fi

  kubectl delete pod gpu-probe -n default --ignore-not-found >/dev/null 2>&1 || true
fi

echo ""
echo "==> Selected mode: $MODE"
echo "==> Updating $APP_FILE to use values-${MODE}.yaml"

# Rewrite the valueFiles block. yq would be cleaner; sed for portability.
# This replaces the single line matching "values-*.yaml" in valueFiles.
python3 - "$APP_FILE" "$MODE" <<'PYEOF'
import sys, re, pathlib
path = pathlib.Path(sys.argv[1])
mode = sys.argv[2]
text = path.read_text()
new = re.sub(r'-\s*values-(cpu|gpu)\.yaml', f'- values-{mode}.yaml', text)
path.write_text(new)
print(f"  Wrote: {path}")
PYEOF

echo ""
echo "Done. Now commit & push:"
echo "  git add apps/model-serving.yaml"
echo "  git commit -m \"chore: auto-detected $MODE mode\""
echo "  git push"
echo ""
echo "ArgoCD will pick up the change on its next reconcile (or click Sync in the UI)."
