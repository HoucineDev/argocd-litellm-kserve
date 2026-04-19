# Swapping models

The whole point of the `model-serving` chart: change the model without touching templates.

## The one-file contract

A "model deployment" = one values file. Example, `values-gemma.yaml`:

```yaml
model:
  name: "gemma-3-1b"
  huggingfaceId: "google/gemma-3-1b-it"
  huggingfaceTokenSecret: "hf-token"      # Gemma is gated

runtime:
  customVllm:
    args:
      - "--max-model-len=4096"
      - "--dtype=bfloat16"
      - "--gpu-memory-utilization=0.80"
```

That's it. Register it by adding the file to `apps/model-serving.yaml`:

```yaml
spec:
  source:
    helm:
      valueFiles:
        - values.yaml
        - values-gpu.yaml         # base (GPU or CPU)
        - values-gemma.yaml       # your model
```

Commit, push, ArgoCD reconciles.

## Picking values for a new model

### `model.huggingfaceId`
The HuggingFace repo. Must be compatible with vLLM — check the [vLLM supported models list](https://docs.vllm.ai/en/latest/models/supported_models.html). If it's not listed, vLLM will probably fail to load it.

### `resources` and `gpu`

Rough VRAM needs in fp16 (roughly 2 bytes per parameter + KV cache):

| Params | fp16 weights | + KV cache @ 2k ctx | Typical GPU |
|--------|--------------|----------------------|-------------|
| 0.5B | 1 GB | 1.3 GB | RTX 3050 4GB ✅ |
| 1B | 2 GB | 2.6 GB | RTX 3050 4GB (tight) |
| 3B | 6 GB | 7 GB | RTX 3070 8GB |
| 7B | 14 GB | 16 GB | A10 24GB |
| 13B | 26 GB | 30 GB | A100 40GB |

For quantized (AWQ, GPTQ, 4-bit) divide by ~3–4.

### `runtime.customVllm.args`

Cheat sheet:

| Flag | When |
|------|------|
| `--max-model-len=N` | Lower = less KV-cache RAM. Default 2048 is safe for chat. |
| `--dtype=auto` | Good default. Forces `bfloat16` on A100/H100/Ampere+, `float16` otherwise. |
| `--dtype=float32` | CPU only. |
| `--gpu-memory-utilization=0.85` | GPU only. Leave 10–15% headroom. |
| `--enforce-eager` | Skip CUDA graph capture. Saves ~500MB VRAM, costs ~10% throughput. Keep on for small GPUs. |
| `--quantization=awq` | Use AWQ quantized weights. Repo must have them. |
| `--tensor-parallel-size=N` | Multi-GPU. Shard model across N GPUs. |

### `runtime.type` choice

- **`custom-vllm`** (default): full vLLM flag control. Use for production and anything non-trivial.
- **`kserve-huggingface`**: KServe's bundled runtime. Simpler, but you lose fine-grained vLLM tuning. Good for a quick smoke test or if you're only serving via HF Transformers (not vLLM).

## Tested combinations

| Model | Mode | Works? | Notes |
|-------|------|--------|-------|
| `Qwen/Qwen2.5-0.5B-Instruct` | CPU | ✅ | Default. ~5 tok/s on modern laptop CPU. |
| `Qwen/Qwen2.5-0.5B-Instruct` | GPU RTX 3050 4GB | ✅ | Comfortable, ~40 tok/s. |
| `HuggingFaceTB/SmolLM2-360M-Instruct` | CPU | ✅ | Smallest viable chat model. |
| `TinyLlama/TinyLlama-1.1B-Chat-v1.0` | GPU RTX 3050 4GB | ✅ (tight) | Needs `--max-model-len=1024`. |
| `google/gemma-3-1b-it` | GPU RTX 3050 4GB | ✅ | Gated, needs HF token. |
| `google/gemma-3-4b-it` | GPU RTX 3050 4GB | ❌ | OOM. Need AWQ variant or bigger GPU. |
| `meta-llama/Llama-3.2-1B-Instruct` | GPU RTX 3050 4GB | ✅ | Gated, Meta license approval needed. |
| `meta-llama/Llama-3.2-3B-Instruct` | GPU A10 24GB | ✅ | Comfortable. |

## Multiple models at once

The chart deploys ONE model per release. To run two, use two Helm releases / two ArgoCD Applications pointing at the same chart with different value files:

```yaml
# apps/model-serving-qwen.yaml
# apps/model-serving-gemma.yaml
```

Then add both to LiteLLM's `model_list` so clients can route by name.
