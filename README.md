# argocd-litellm-kserve

End-to-end GitOps project to deploy a generalized LLM serving stack on a local
`kind` cluster running on Windows (Docker Desktop + WSL2), then promote the same
manifests unchanged to a real GPU cluster.

```
Client ──► LiteLLM ──► Guardrails AI ──► KServe/vLLM InferenceService
              ▲             │                    │
              └── ArgoCD (GitOps) ──► Git repo (this repo)
```

## What this gives you

- **ArgoCD** installed via Helm, configured in App-of-Apps mode.
- **KServe** (+ cert-manager + Knative Serving) installed as ArgoCD `Applications`.
- **LiteLLM** proxy as the single OpenAI-compatible entrypoint, routing to any
  model (KServe in-cluster, or external providers like Anthropic/OpenAI/Groq).
- **Guardrails AI** sidecar/pre-hook running input + output validation
  (PII, jailbreak, toxicity, secrets).
- **`model-serving` Helm chart** — the generic part. One chart, one set of
  values, any HuggingFace model ID. Swap `model.name: Qwen/Qwen2.5-0.5B-Instruct`
  for anything else and redeploy.

## Critical: your hardware situation

You have an **RTX 3050 Laptop 4GB on Windows (WDDM driver)**. Two honest facts:

1. **4GB VRAM** is below the working set of almost every "small" LLM in fp16.
   After kind overhead and vLLM's KV cache you get ~3 GB usable. Models that
   fit: `Qwen/Qwen2.5-0.5B-Instruct` (default), `HuggingFaceTB/SmolLM2-360M-Instruct`,
   `TinyLlama/TinyLlama-1.1B-Chat-v1.0` in AWQ.
2. **GPU passthrough from Windows → Docker Desktop → kind → pod is fragile.**
   NVML library propagation into kind's nested containers is a known pain point.
   Expect to fight it. For that reason this project ships **two modes**:

   | Mode | Flag | What runs | Use when |
   |------|------|-----------|----------|
   | `cpu` (default for local) | `values-cpu.yaml` | vLLM CPU build, Qwen2.5-0.5B | You want the full pipeline working end-to-end on Windows *today* |
   | `gpu` | `values-gpu.yaml` | vLLM CUDA, any model that fits | You've got GPU passthrough working, or you're on real infra |

Start in CPU mode. Get the GitOps + LiteLLM + Guardrails → KServe chain green
end-to-end. **Then** tackle the GPU plumbing as a separate problem.

## Repo layout

```
.
├── bootstrap/              # One-time: install ArgoCD itself
│   ├── install-argocd.sh
│   └── values-argocd.yaml
├── apps/                   # ArgoCD Applications (App-of-Apps pattern)
│   ├── root-app.yaml       # The one app you kubectl apply; it spawns the rest
│   ├── cert-manager.yaml
│   ├── knative-serving.yaml
│   ├── kserve.yaml
│   ├── litellm.yaml
│   └── model-serving.yaml  # Points at charts/model-serving
├── charts/
│   └── model-serving/      # The generalized model-deployment chart
│       ├── Chart.yaml
│       ├── values.yaml             # Defaults (GPU-capable)
│       ├── values-cpu.yaml         # Overlay: CPU mode for your laptop
│       ├── values-gpu.yaml         # Overlay: real GPU
│       ├── values-gemma.yaml       # Example: swap model to Gemma 1B
│       ├── templates/
│       │   ├── servingruntime.yaml       # vLLM runtime (CPU or GPU)
│       │   ├── inferenceservice.yaml     # The KServe IS
│       │   ├── guardrails-deployment.yaml
│       │   ├── guardrails-service.yaml
│       │   ├── guardrails-configmap.yaml # Validators config
│       │   └── _helpers.tpl
│       └── ci/
│           └── test-values.yaml
├── scripts/
│   ├── 00-create-kind-cluster.ps1   # Windows PowerShell
│   ├── 00-create-kind-cluster.sh    # Bash (WSL/Linux)
│   ├── 01-bootstrap.sh
│   ├── 02-port-forward.ps1
│   ├── test-chat.sh                 # Hit LiteLLM end-to-end
│   └── test-guardrails.sh           # Hit the Guardrails service directly
└── docs/
    ├── SETUP-WINDOWS.md             # The Windows-specific gotchas
    ├── SWAPPING-MODELS.md
    └── TROUBLESHOOTING.md
```

## 15-minute quickstart (Windows, CPU mode)

```powershell
# In PowerShell, repo root
.\scripts\00-create-kind-cluster.ps1
bash scripts/01-bootstrap.sh         # Installs ArgoCD + applies root app
.\scripts\02-port-forward.ps1        # ArgoCD UI: https://localhost:8443
                                     # LiteLLM:   http://localhost:4000
bash scripts/test-chat.sh
```

See `docs/SETUP-WINDOWS.md` for the full walkthrough and `docs/TROUBLESHOOTING.md`
for the GPU-passthrough-into-kind pain points.
