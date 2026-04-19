# Troubleshooting

Problems you will hit, grouped by symptom.

## GPU-related

### `GPU probe TIMED OUT` during detect-gpu-mode.sh

This is the #1 problem on Windows+WSL2+kind. The node advertises `nvidia.com/gpu` but pods can't actually use it. Root cause is almost always one of:

1. **NVML library not propagated into the kind node container.** kind runs Kubernetes nodes as Docker containers; the NVIDIA driver libraries from WSL2 need to be mounted in. The `kind-config.yaml` in this repo includes `extraMounts: /usr/lib/wsl/lib`, which helps, but doesn't always suffice.

2. **No `nvidia` RuntimeClass in the cluster.** Check:
   ```bash
   kubectl get runtimeclass
   ```
   If empty, create one:
   ```bash
   cat <<EOF | kubectl apply -f -
   apiVersion: node.k8s.io/v1
   kind: RuntimeClass
   metadata:
     name: nvidia
   handler: nvidia
   EOF
   ```
   And in `values-gpu.yaml`, set `gpu.runtimeClassName: "nvidia"`.

3. **nvidia-container-toolkit not installed inside the kind node.** kind's node image doesn't have it by default. The fix involves installing the toolkit inside the node container manually:
   ```bash
   docker exec -it llm-platform-control-plane bash
   # inside:
   apt-get update && apt-get install -y nvidia-container-toolkit
   nvidia-ctk runtime configure --runtime=containerd --set-as-default
   systemctl restart containerd
   ```
   Yes this is gross. The alternative is to use minikube with `--driver=docker --gpus=all`, which handles more of this automatically. But since you explicitly chose kind, this is the path.

**Honest recommendation**: if `detect-gpu-mode.sh` fails twice, stop fighting it. Use CPU mode for local iteration, and test the GPU path on a real Linux machine with the NVIDIA GPU Operator installed. That's what your Exaion cluster has; your laptop is a harder environment than production.

### `spec.runtimeClassName` validation error

The exact error you hit earlier. Two usual causes:

- **Field placed wrong.** In a `ServingRuntime`, `runtimeClassName` goes at `spec.runtimeClassName`, not inside `spec.containers[*]`. The chart in this repo puts it correctly at pod spec level (see `templates/servingruntime.yaml`).
- **Named RuntimeClass doesn't exist.** If your values say `runtimeClassName: "nvidia"` but `kubectl get runtimeclass nvidia` returns NotFound, the API server rejects the pod. Either create the RuntimeClass (see above) or unset the field: `gpu.runtimeClassName: ""`.

### Pod stuck `Pending` with `0/1 nodes are available: 1 Insufficient nvidia.com/gpu`

The node is advertising zero GPUs even though `nvidia-smi` works on the host. Usually means the NVIDIA device plugin DaemonSet isn't running or crashed. For kind you typically install it manually:

```bash
kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.16.2/deployments/static/nvidia-device-plugin.yml
```

Check its logs:
```bash
kubectl -n kube-system logs -l name=nvidia-device-plugin-ds
```
`Failed to initialize NVML: could not load NVML library` = back to the NVML propagation problem above.

## ArgoCD / sync problems

### Application stays `OutOfSync` or `Unknown`

```bash
kubectl -n argocd describe application <name>
```
Common causes:
- `repoURL` still says `YOUR_USERNAME`. Did you do the find/replace?
- Repo is private; ArgoCD doesn't have credentials. Add a repo credential in the ArgoCD UI (Settings → Repositories) or use a public repo for local testing.

### `comparison error` mentioning CRDs

KServe ships large CRDs that can exceed the default annotation size. The `apps/kserve.yaml` already sets `ServerSideApply=true` and `Replace=true`. If you still see it:

```bash
kubectl -n argocd edit application kserve-crd
# Add under spec.syncPolicy.syncOptions:
#   - ApplyOutOfSyncOnly=true
```

### Knative operator installs but KnativeServing CR never becomes Ready

The operator needs its CRDs before the CR can be applied. The root App-of-Apps uses sync-waves (`-5` for operator, `-4` for the CR) to order them. If you still hit a race, manually sync in order:

```bash
argocd app sync knative-operator
argocd app sync knative-serving
```

## LiteLLM

### LiteLLM pod `CrashLoopBackOff` with Postgres connection error

The Helm chart spins up its own Postgres by default. If it doesn't come up fast enough, LiteLLM crashes. Usually self-heals within 2 min — give it time. If not:

```bash
kubectl -n litellm get pods
kubectl -n litellm logs <litellm-pod>
```

### `guardrails_ai` callback: connection refused

LiteLLM is trying to reach Guardrails at `guardrails.model-serving.svc.cluster.local:8000` but either:
- The Guardrails Service isn't called exactly `guardrails` (check `kubectl -n model-serving get svc`). The chart hardcodes this name — don't rename without updating `apps/litellm.yaml` too.
- The Guardrails pod hasn't finished pulling the `guardrailsai/guardrails-server` image. First pull is ~1 GB, can take a while.

### `local-llm` returns 503 from LiteLLM

Means LiteLLM reached the InferenceService but it returned an error. Skip LiteLLM and hit the model directly:

```bash
kubectl -n model-serving port-forward svc/local-llm-predictor 8080:80
curl -sS http://localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"local-llm","messages":[{"role":"user","content":"hi"}]}'
```

Then look at the pod:
```bash
kubectl -n model-serving logs -l serving.kserve.io/inferenceservice=local-llm -c kserve-container --tail=100
```
Common issues: OOMKilled (bump `resources.limits.memory`), HuggingFace rate limit, or vLLM arg it doesn't recognize (e.g., `--gpu-memory-utilization` in CPU mode — the `values-cpu.yaml` overlay removes it).

## Model-specific

### vLLM `CUDA out of memory` on RTX 3050 4GB

Options, in order of impact:
1. Lower `--max-model-len` to 1024 or 512.
2. Add `--enforce-eager` (already in defaults; saves ~500 MB).
3. Lower `--gpu-memory-utilization` to 0.7 (but usually the problem isn't reservation, it's that the model itself + KV cache overflow).
4. Switch to a quantized model: `--quantization=awq` with an AWQ-compatible HF repo.
5. Drop to a smaller model. `Qwen/Qwen2.5-0.5B-Instruct` is 0.5B params; `HuggingFaceTB/SmolLM2-360M-Instruct` is smaller still.

### Gated model (Llama, Gemma) returns 401

Create the HF token secret and reference it:

```bash
kubectl -n model-serving create secret generic hf-token \
  --from-literal=HF_TOKEN=hf_xxxxxxxxxxxx
```

Then in your values file:
```yaml
model:
  huggingfaceTokenSecret: hf-token
  huggingfaceTokenSecretKey: HF_TOKEN
```
