# Qwen3.6 Reddit 5090 Comparison Benchmark Matrix

Goal: compare this repo's Strix Halo defaults against the Reddit Qwen3.6 27B
Q6_K / RTX 5090 profile using the same local GGUF and prompt set.

## Preconditions

- Model path under `MODELS_DIR`, ideally `Qwen3.6-27B-MTP-Q6_K.gguf`.
- Built image: `vulkan` and/or `vulkan-fpx`; ROCm images should be built before
  ROCm runs.
- For every run, capture:
  - prompt tok/s
  - generation tok/s
  - latency p50/p95 when using server benchmark
  - memory use
  - draft acceptance / speculative stats if logged
  - count of `forcing full prompt re-processing due to lack of cache data`
  - crash/OOM status

## Matrix

| ID | Purpose | Backend | Key flags/env |
| --- | --- | --- | --- |
| B0 | Baseline no MTP | `vulkan` | `bin/run.sh vulkan server <model> -ctk q8_0 -ctv q8_0 --kv-unified --cache-ram 32768 --ctx-checkpoints 8 --checkpoint-min-step 256` |
| B1 | Current repo MTP default | `vulkan` | `bin/run.sh vulkan mtp-server <model>` (depth 3 + ngram-map-k4v) |
| B2 | Pure MTP depth 2 | `vulkan` | `LLAMA_MTP_NGRAM=0 bin/run.sh vulkan mtp-server <model> 2` |
| B3 | Pure MTP depth 3 | `vulkan` | `LLAMA_MTP_NGRAM=0 bin/run.sh vulkan mtp-server <model> 3` |
| B4 | Pure MTP depth 5 | `vulkan` | `LLAMA_MTP_NGRAM=0 bin/run.sh vulkan mtp-server <model> 5` |
| B5 | Reddit-like depth 10 / p-min 0.5 | `vulkan` | `LLAMA_MTP_NGRAM=0 LLAMA_SPEC_DRAFT_N_MAX=10 LLAMA_SPEC_DRAFT_P_MIN=0.5 LLAMA_CONTEXT=196608 LLAMA_BATCH=512 LLAMA_UBATCH=512 bin/run.sh vulkan mtp-server <model> --cache-ram 32768 --ctx-checkpoints 8 --checkpoint-min-step 256 -ctk q8_0 -ctv q8_0 --kv-unified --reasoning on --reasoning-budget 16384` |
| B6 | Batch/ubatch 512/512 only | `vulkan` | Same as B1 but `LLAMA_BATCH=512 LLAMA_UBATCH=512` |
| B7 | ROCm default 4096/2048 | `rocm` | Same model/profile after ROCm image build; leave `LLAMA_BATCH/UBATCH` default |
| B8 | Vulkan default 2048/512 | `vulkan` | Same model/profile with default Vulkan batch knobs |
| B9 | FPX MTP default | `vulkan-fpx` | `bin/run.sh vulkan-fpx mtp-server <model>`; omit `--checkpoint-min-step` |

## Mapping to plan steps

- B0 = baseline no MTP.
- B1 = current repo MTP default.
- B2/B3/B4 = pure MTP depth sweep 2/3/5.
- B5 = Reddit-like depth 10, `p-min=0.5`.
- B6 = batch/ubatch 512/512.
- B7 = ROCm default 4096/2048.
- B8 = Vulkan default 2048/512.

## Patch success criteria

- Images build successfully with Qwen3.6 external patches applied.
- `llama-server --help` still exposes required checkpoint/cache/speculation flags.
- Multi-turn runs with Qwen3.6 no longer repeatedly log `forcing full prompt re-processing due to lack of cache data` when a usable checkpoint exists.
- Prompt-cache shrink/expand logs appear for recurrent/hybrid models and do not appear for non-recurrent models.
- No new crashes/OOMs compared with unpatched images at the same context/batch settings.
- MTP throughput improves versus no-MTP baseline or at least does not regress enough to justify disabling speculation.
- Quality sanity prompts remain stable; if quality regresses, compare `q8_0/q8_0` against `f16/f16` KV.

## Remaining open questions

- Which exact local Qwen3.6 27B MTP Q6_K GGUF should be used for the matrix?
- Should ROCm/ROCm-next builds be validated before committing/publishing, or is Vulkan-only validation enough for the next checkpoint?
- Should patched images remain always-on, or should a future build arg allow disabling Qwen3.6 cache patches after upstream changes land?
- Does `--spec-draft-p-min 0.5` help on Strix Halo, or is FPX's default `0.75` / stock default `0.0` better?
- Does pure MTP beat MTP+ngram-map-k4v locally?
