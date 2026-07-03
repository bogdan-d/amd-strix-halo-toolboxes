# Qwen3.6 27B Q6 5090 Reddit Comparison Notes

Source post: <https://www.reddit.com/r/LocalLLM/comments/1ullrvq/qwen36_27b_q6_5090_maximum_llamacpp_optimization/>

Direct Reddit access was blocked during capture (`403` / verification page), but web search found the raw Pastebins linked from the post. Facts below come from indexed search output available in-session, raw Pastebins, upstream GitHub issue/PR metadata, and this repo's local docs. Treat Reddit-specific performance numbers as community claims until reproduced locally.

## Reddit profile facts captured

| Area | Reddit post claim |
| --- | --- |
| Model | Unsloth Qwen3.6 27B Q6_K / Q6K with MTP |
| GPU | NVIDIA RTX 5090 32GB |
| Host | Ryzen 9800X3D, 64GB RAM, Ubuntu text mode to maximize VRAM |
| llama.cpp | Recent build identified as commit `86b9470` |
| Throughput | Claimed 100-233 tok/s, mean about 140.7 tok/s across ~20h workloads |
| Context | `196608` tokens (192k) |
| Main KV | `-ctk q8_0 -ctv q8_0`, `--kv-unified` |
| Speculation | MTP draft decoding |
| Draft depth | `--spec-draft-n-max 10` |
| Draft threshold | `--spec-draft-p-min 0.5` |
| Batch | `--batch-size 512` |
| Ubatch | `--ubatch-size 512` |
| Parallelism | single concurrency / `--parallel 1` |
| VRAM | about 32,036 MiB / 32,768 MiB under load |
| Cache/checkpoint | `--cache-ram 32768`, custom checkpoint/recurrent patches |
| Reasoning | `--reasoning-budget 16384`; reasoning enabled |
| Caveat | Depends on custom llama.cpp patches for hybrid/sliding-window/recurrent cache behavior |

Important reported log symptom:

```text
forcing full prompt re-processing due to lack of cache data
```

The post attributes much of the optimization to avoiding repeated full prompt reprocessing for Qwen3.6 hybrid/sliding-window/recurrent cache behavior, not only to CUDA flags.


## Raw Pastebins found

| Artifact | URL | Notes |
| --- | --- | --- |
| Dockerfile / checkpoint patch | <https://pastebin.com/raw/jyrhvesQ> | CUDA 12.8 Ubuntu container; applies checkpoint search patch plus minimal recurrent patch before building `llama-server`. |
| Minimal PR24785 diff | <https://pastebin.com/raw/E55YG5NS> | Adds recurrent memory shrink/expand APIs and server prompt-cache shrink/expand calls. |
| Runtime command | <https://pastebin.com/raw/P57Uk6rz> | `llama-server` flags for Qwen3.6 27B MTP Q6_K on 5090. |

## Upstream refs mentioned / relevant

Checked through GitHub API on 2026-07-03:

| Ref | State | Type | Title | URL |
| --- | --- | --- | --- | --- |
| `#22384` | closed | issue | `server: fix context checkpoint restore for hybrid/recurrent models (DeltaNet/Mamba)` | <https://github.com/ggml-org/llama.cpp/issues/22384> |
| `#20225` | closed | issue | `Eval bug: Qwen 3.5 Full prompt re-processing on every conversation turn` | <https://github.com/ggml-org/llama.cpp/issues/20225> |
| `#24055` | open | issue | `Misc. bug: Context checkpoints always invalidated on hybrid/recurrent models` | <https://github.com/ggml-org/llama.cpp/issues/24055> |
| `#24785` | open | PR | `server: add recurrent state shrink/expand for prompt cache (#22746)` | <https://github.com/ggml-org/llama.cpp/pull/24785> |
| `#22673` | closed | PR | `llama + spec: MTP Support` | <https://github.com/ggml-org/llama.cpp/pull/22673> |

## Current repo facts to compare

| Area | Current repo behavior |
| --- | --- |
| Stock llama.cpp pin | `.env` `STOCK_LLAMA_BRANCH=fdb1db877c526ec90f668eca1b858da5dba85560` |
| ROCmFPX pin | `.env` `FPX_LLAMA_BRANCH=baed43ed9914b4f855afbeb2faec0b97cf0eace0` |
| Required Strix flags | `-fa 1` and `--no-mmap` in `bin/run.sh` direct server/CLI flows |
| Direct context default | `LLAMA_CONTEXT=131072` |
| Generated Qwen3.6 preset context | `ctx-size = 262144` total server pool; with `parallel = 4`, about 65536 per slot |
| Direct batch defaults | Vulkan `2048/512`, ROCm `4096/2048`, ROCmFPX `512/512` |
| Generated Qwen3.6 stock KV | `q8_0` main KV, device KV offload, unified KV |
| Generated checkpoints | `ctx-checkpoints = 32`, `checkpoint-min-step = 256`, `cache-ram = 32768` |
| Direct `mtp-server` | MTP depth default `3`, plus `ngram-map-k4v`, `-np 1` |
| ROCmFPX generated MTP | depth `5` for dense MTP models; MoE depth `2`; f16 draft KV |
| Unsloth MTP guidance | depth `2` often best; benchmark `1..6`; MTP adds about 1GB memory |

## Initial comparison takeaways

- Reddit profile is CUDA/5090-specific; throughput is not portable to Strix Halo.
- Transferable knobs: pure MTP vs MTP+ngram, draft depth, `--spec-draft-p-min`, single-slot serving, `512/512` batch sizing, Q8 KV, and cache/checkpoint behavior.
- This repo already addresses the same symptom at config level with `ctx-checkpoints = 32`, `checkpoint-min-step = 256`, and cache RAM, but does not yet carry the reported custom source patches.
- Raw Pastebin patch diffs are available; next step is to review and adapt them to this repo's pinned stock and ROCmFPX source trees.

## Exact runtime command captured from Pastebin P57Uk6rz

The linked compose command uses this effective `llama-server` profile:

```bash
llama-server \
  -m /models/Qwen3.6-27B-MTP-Q6_K.gguf \
  -c 196608 -ngl 99 --cache-ram 32768 --no-mmap \
  --spec-type draft-mtp --spec-draft-n-max 10 --spec-draft-p-min 0.5 \
  --flash-attn on -b 512 -ub 512 --parallel 1 \
  --checkpoint-min-step 256 --ctx-checkpoints 8 \
  -ctk q8_0 -ctv q8_0 --kv-unified \
  --temp 0.6 --top-k 20 --top-p 0.95 --min-p 0.0 \
  --presence-penalty 0.0 --repeat-penalty 1.0 --no-mmproj \
  --jinja --reasoning on --reasoning-budget 16384 \
  --perf --metrics --port 8080 --host 0.0.0.0 --alias chat
```

## Build validation notes

- `vulkan` stock image built successfully with the external Qwen3.6 patches.
- `vulkan-fpx` image built successfully with the ROCmFPX-adapted recurrent patch.
- ROCm and ROCm-next builds were intentionally skipped in-session because they are slower; test later before publishing.
- `llama-server --help` on both built Vulkan images exposes `--spec-type`, `--spec-draft-p-min`, `--ctx-checkpoints`, and `--cache-ram`. Stock also exposes `--checkpoint-min-step`; the ROCmFPX fork help does not show that option.
