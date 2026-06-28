# llama.cpp Target Reference

This is a local decision aid for choosing which `llama.cpp` binaries to build
into the next-workflow images. It is based on the `llama*` tools observed in the
locally built `rocm`, `rocm-next`, and `vulkan` images before narrowing the
build targets.

The current next workflow builds only:

- `llama-server`
- `llama-cli`
- `llama-bench`
- `llama-gguf-split`
- `llama-quantize`

## Runtime Targets

| Target | Purpose | Local status |
| :--- | :--- | :--- |
| `llama-server` | HTTP server with OpenAI-compatible endpoints, Web UI, routing, embeddings/reranking modes, multimodal flags, and speculative decoding flags. | Kept. Primary workflow. |
| `llama-cli` | Terminal inference tool for one-shot prompts, chat, device listing, and quick model checks. | Kept. Used by `cli` and `list-devices`. |
| `llama-bench` | Throughput/latency benchmark tool. | Kept. Used by `bench`. |
| `llama-gguf-split` | Split or combine large GGUF model files. | Kept. Useful model-file utility. |
| `llama-quantize` | Quantize model weights. | Kept. Needed for ROCmFPX/ROCmFP4 model prep in the fork images and useful in stock images. |
| `llama-mtmd-cli` | Standalone multimodal CLI for image/audio-capable models using the mtmd path. | Not built. Reconsider if testing multimodal outside `llama-server`. |
| `llama-embedding` | Standalone embedding example/tool. | Not built. Reconsider for dedicated embedding tests outside server mode. |
| `llama-tokenize` | Tokenization helper for inspecting prompt tokenization. | Not built. Reconsider when debugging templates or context usage. |

## Model Prep and Inspection

| Target | Purpose | Local status |
| :--- | :--- | :--- |
| `llama-gguf` | Inspect or manipulate GGUF metadata. | Not built. |
| `llama-gguf-hash` | Hash GGUF contents for integrity or reproducibility checks. | Not built. |
| `llama-imatrix` | Generate importance matrices used by quantization workflows. | Not built. |
| `llama-perplexity` | Measure perplexity for model evaluation. | Not built. |
| `llama-export-lora` | Export LoRA data. | Not built. |
| `llama-finetune` | Fine-tuning utility. | Not built. |
| `llama-cvector-generator` | Generate control vectors. | Not built. |
| `llama-convert-llama2c-to-ggml` | Convert llama2.c-style models to GGML format. | Not built. |

## Examples, Experiments, and Bench Helpers

| Target | Purpose | Local status |
| :--- | :--- | :--- |
| `llama-batched` | Batched decoding example. | Not built. |
| `llama-batched-bench` | Batch-specific benchmark. | Not built. |
| `llama-parallel` | Parallel decoding example. | Not built. |
| `llama-speculative` | Standalone speculative decoding example. | Not built. Server already exposes speculative flags. |
| `llama-speculative-simple` | Minimal speculative decoding example. | Not built. |
| `llama-lookahead` | Lookahead decoding experiment/example. | Not built. |
| `llama-lookup` | Lookup decoding/cache utility. | Not built. |
| `llama-lookup-create` | Create lookup data. | Not built. |
| `llama-lookup-merge` | Merge lookup data. | Not built. |
| `llama-lookup-stats` | Inspect lookup data statistics. | Not built. |
| `llama-passkey` | Long-context passkey retrieval evaluation. | Not built. |
| `llama-retrieval` | Retrieval example using embeddings. | Not built. |
| `llama-completion` | Completion example/tool. | Not built. |
| `llama-simple` | Minimal inference example. | Not built. |
| `llama-simple-chat` | Minimal chat example. | Not built. |
| `llama-eval-callback` | Evaluation callback example. | Not built. |
| `llama-fit-params` | Fit-parameter helper/test tool. | Not built. |
| `llama-idle` | Idle/runtime behavior test tool. | Not built. |
| `llama-results` | Results processing utility. | Not built. |

## Specialized Modalities

| Target | Purpose | Local status |
| :--- | :--- | :--- |
| `llama-diffusion-cli` | Diffusion model CLI. | Not built. |
| `llama-tts` | Text-to-speech tool. | Not built. |

## Developer and Debug Tools

| Target | Purpose | Local status |
| :--- | :--- | :--- |
| `llama` | Upstream command dispatcher/wrapper. | Not built. The next workflow calls concrete binaries directly. |
| `llama-debug` | General debug utility. | Not built. |
| `llama-debug-template-parser` | Chat-template parser debug utility. | Not built. |
| `llama-template-analysis` | Chat-template analysis tool. | Not built. |
| `llama-gen-docs` | Generate llama.cpp argument documentation from built metadata. | Not built. Build/dev only. |
| `rpc-server` | RPC backend worker for distributed llama.cpp runs. | Not built. RPC is intentionally disabled in the next Containerfile. |

## Reconsideration Notes

Good first additions if the workflow expands:

- Add `llama-mtmd-cli` for standalone multimodal testing.
- Add `llama-tokenize` for prompt/template debugging.
- Add `llama-gguf` and `llama-gguf-hash` for local model inspection.
- Add `llama-imatrix` if importance-matrix generation should happen inside
  these runtime images.
- Add `rpc-server` only if distributed inference returns to the next workflow;
  that also requires re-enabling `GGML_RPC`.
