# Setup on Windows

Step-by-step for a clean Windows 11 machine with Docker Desktop.

## Prerequisites

Install once via winget (PowerShell as admin):

```powershell
winget install Kubernetes.kind
winget install Kubernetes.kubectl
winget install Helm.Helm
winget install Git.Git
winget install jqlang.jq
winget install Python.Python.3.11      # only for detect-gpu-mode.sh
```

Docker Desktop: enable **WSL2 backend** (Settings → General) and **Kubernetes is NOT needed** — we use kind, which runs its own cluster inside Docker.

For GPU: Settings → Resources → turn on GPU support. Verify with:

```powershell
docker run --rm --gpus=all nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda11.7.1
```

If that prints `Test PASSED`, GPU works in plain Docker. That's half the battle — kind is the other half, see `TROUBLESHOOTING.md`.

## Clone and push to your GitHub

```powershell
cd C:\Users\<you>\dev
git clone <wherever-you-put-this-zip-or-repo> argocd-litellm-kserve
cd argocd-litellm-kserve

# Create your own GitHub repo (via gh CLI or the web UI), then:
git remote set-url origin https://github.com/<YOUR_USERNAME>/argocd-litellm-kserve.git
git push -u origin main
```

Now edit **three files** to point at your remote:

- `apps/root-app.yaml` — `repoURL:`
- `apps/knative-serving.yaml` — `repoURL:`
- `apps/model-serving.yaml` — `repoURL:`

A single find/replace on `YOUR_USERNAME` in the repo root does it. Commit + push.

## Bring up the cluster

```powershell
.\scripts\00-create-kind-cluster.ps1
```

Verify:

```powershell
kubectl get nodes
# NAME                         STATUS   ROLES           AGE   VERSION
# llm-platform-control-plane   Ready    control-plane   30s   v1.29.x
```

## Bootstrap ArgoCD

In WSL (bash) from the repo root:

```bash
bash scripts/01-bootstrap.sh
```

Save the admin password it prints.

## Choose GPU or CPU mode

```bash
bash scripts/detect-gpu-mode.sh
```

This runs a CUDA probe pod. If it succeeds → rewrites `apps/model-serving.yaml` to use `values-gpu.yaml`. If it fails (very common on WSL2+kind) → falls back to `values-cpu.yaml`. Commit & push the update; ArgoCD reconciles.

## Watch everything come up

```powershell
# Watch all ArgoCD Applications
kubectl -n argocd get applications -w

# Wait for the model pod specifically (this is the slow one — downloads weights)
kubectl -n model-serving get pods -w
```

Expected timings on a laptop:

| Stage | Wall time |
|-------|-----------|
| ArgoCD install | 1 min |
| cert-manager → Knative → KServe CRDs+controller | 3–5 min |
| LiteLLM | 2 min (pulls Postgres image too) |
| Model pod (CPU, Qwen2.5-0.5B) | 3–4 min cold (weight download + vLLM init) |
| Model pod (GPU, same model) | 1–2 min |

## Port-forward and test

```powershell
.\scripts\02-port-forward.ps1
```

In another terminal (WSL):

```bash
bash scripts/test-chat.sh
```

You should see three JSON responses: a normal reply, a PII-masked reply, and a blocked jailbreak.

## Teardown

```powershell
kind delete cluster --name llm-platform
```
