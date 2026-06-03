# llama.cpp Argument Map

This is a decision-oriented map for `llama-cli` and `llama-server` arguments.
It is based on the generated upstream docs for `llama.cpp` `master` as checked
on 2026-06-01:

- <https://github.com/ggml-org/llama.cpp/blob/master/tools/cli/README.md>
- <https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md>

Always verify against the exact binary you are running:

```bash
bin/run.sh rocm run llama-cli --help
bin/run.sh rocm run llama-server --help
```

## Argument Precedence

For ordinary `llama-server` and `llama-cli` arguments, command-line arguments
override matching environment variables such as `LLAMA_ARG_BATCH` or
`LLAMA_ARG_UBATCH`.

For `llama-server --models-preset` router mode, preset options are applied in
this order:

1. Command-line arguments passed to `llama-server`
2. Model-specific options in the selected preset section
3. Global options in the preset file's `[*]` section

That means command-line values passed by `bin/run.sh`, such as
`--batch-size` and `--ubatch-size`, override the fallback values in
the generated preset based on `models-template.ini`. Request-time generation
options from API calls can still override sampling defaults for that request,
but load-time settings such as context size, batch sizes, GPU layers, device
placement, and KV cache types are fixed when the model instance starts.

## Strix Halo Baseline

These are the first knobs to decide for this repo.

| Argument | Use here | Why |
| --- | --- | --- |
| `-fa`, `--flash-attn` | Use `-fa 1` or `--flash-attn on` | Required for reliable Strix Halo runs. |
| `--no-mmap` | Use for server and CLI | Avoids memory fragmentation/page behavior that can crash large unified-memory runs. |
| `-ngl`, `--n-gpu-layers` | Use `999`, `all`, or `auto` | Full iGPU offload is the normal target. Existing helpers use `999`. |
| `-c`, `--ctx-size` | Direct runs: start at `131072`; active Qwen3.6 presets: `262144` total | 131k is the conservative Strix Halo baseline; with server slots, active presets treat 256k as the shared context/KV pool. |
| `-b`, `--batch-size` | Vulkan: `2048`; ROCm: `4096` | Logical batch. Keep ROCm at least 2x the 2048 physical microbatch for better prefill saturation. |
| `-ub`, `--ubatch-size` | Vulkan: `512`; ROCm: `2048` | Physical batch. ROCm handles the larger Strix Halo value; keep Vulkan below the values that are known to crash. |
| `-ctk`, `-ctv` | Active presets use `q8_0` | Q8 KV roughly halves KV memory versus `f16` with low observed quality impact; keep `f16` as the comparison baseline. |
| `--models-preset` | Use for multi-model routing | Keeps repeated server arguments in an INI file. |
| `--spec-type draft-mtp` | Use only with MTP-capable builds/models | Enables MTP draft decoding. Pair with `--spec-draft-n-max`. |

The generated `jcbtc/qwen3.6-35b-a3b-crown-halo-mtp-dynamic` routes are a
model-card exception to the shared defaults: they keep `ctx-size = 131072`,
`parallel = 1`, `split-mode = row`, `cache-type-k/v = f16`,
`spec-draft-type-k/v = f16`, `spec-draft-n-max = 4`, the Strix polling flags,
and `batch-size = 2048` / `ubatch-size = 512` directly in the model sections.
The generator always emits both reasoning-on and reasoning-off MTP routes for
that model.

## Mental Model

Most flags fall into these decisions:

| Area | Main question | Common flags |
| --- | --- | --- |
| Model source | Where does the model come from? | `-m`, `-hf`, `-hff`, `--models-dir`, `--models-preset` |
| Memory and context | How much state do we keep? | `-c`, `-b`, `-ub`, `--no-mmap`, `-ctk`, `-ctv` |
| Device placement | What runs on GPU vs CPU? | `-ngl`, `-dev`, `-sm`, `-ts`, `--cpu-moe`, `--kv-offload` |
| Generation behavior | How random/controlled is output? | `--temp`, `--top-p`, `--min-p`, `--repeat-penalty`, `--json-schema` |
| Chat formatting | How are messages converted to tokens? | `--jinja`, `--chat-template`, `--reasoning`, `-sys` |
| Server operation | How is HTTP exposed and routed? | `--host`, `--port`, `-np`, `--api-key`, `--metrics`, `--ui` |
| Speculation | How do we draft tokens faster? | `--spec-type`, `--model-draft`, `--spec-draft-n-max` |

## Startup and Introspection

| Argument | Applies | Meaning |
| --- | --- | --- |
| `-h`, `--help`, `--usage` | both | Print usage. |
| `--version` | both | Print build/version info. |
| `--license` | both | Print license/dependency info. |
| `-cl`, `--cache-list` | both | Show cached models. |
| `--completion-bash` | both | Emit shell completion script. |
| `--list-devices` | both | Show visible acceleration devices. Use this first in containers. |

## CPU Scheduling

Usually leave these alone on Strix Halo until profiling shows CPU contention.

| Argument | Applies | Meaning |
| --- | --- | --- |
| `-t`, `--threads` | both | CPU generation threads. |
| `-tb`, `--threads-batch` | both | CPU prompt/batch processing threads. |
| `-C`, `--cpu-mask` | both | CPU affinity mask for generation. |
| `-Cr`, `--cpu-range` | both | CPU affinity range for generation. |
| `--cpu-strict` | both | Enforce strict CPU placement. |
| `--prio` | both | Process/thread priority. |
| `--poll` | both | Polling level while waiting for work. |
| `-Cb`, `--cpu-mask-batch` | both | CPU affinity mask for batch processing. |
| `-Crb`, `--cpu-range-batch` | both | CPU affinity range for batch processing. |
| `--cpu-strict-batch` | both | Strict CPU placement for batch processing. |
| `--prio-batch` | both | Batch thread priority. |
| `--poll-batch` | both | Batch polling behavior. |
| `--numa` | both | NUMA placement mode. Mostly irrelevant on single Strix Halo desktops. |

## Context, Batch, and Runtime State

| Argument | Applies | Meaning |
| --- | --- | --- |
| `-c`, `--ctx-size` | both | Token context window. Bigger uses more KV memory. |
| `-n`, `--predict`, `--n-predict` | both | Max generated tokens. `-1` means unbounded. |
| `-b`, `--batch-size` | both | Logical max batch. Affects prompt throughput and memory. |
| `-ub`, `--ubatch-size` | both | Physical microbatch. Critical perf/memory knob. |
| `GGML_HIP_MAX_BATCH_SIZE` | ROCm env | HIP backend batch cap. This repo sets it to `2048` for ROCm/ROCm-next helper runs unless overridden. |
| `--keep` | both | Tokens kept when context shifts. |
| `--swa-full` | both | Use full-size sliding-window-attention cache. |
| `--perf`, `--no-perf` | both | Enable internal performance timings. |
| `-e`, `--escape`, `--no-escape` | both | Interpret escaped sequences in prompt input. |
| `-np`, `--parallel` | both | CLI: parallel sequences; server: slots. In server use, `ctx-size` is the total KV/context pool and is split across slots. |
| `--context-shift`, `--no-context-shift` | both | Allow shifting context for long/infinite generation. |
| `-ctxcp`, `--ctx-checkpoints`, `--swa-checkpoints` | both | Maximum context checkpoints per slot. Active Qwen3.6 presets use `32` to avoid repeated full prompt re-processing in 4-slot agent runs. |
| `-cms`, `--checkpoint-min-step` | both | Minimum token spacing between context checkpoints. Current image default is `256`; active presets set `256` explicitly. |
| `-cram`, `--cache-ram` | both | RAM limit for prompt/cache checkpointing. Active Qwen3.6 presets use `32768` MiB on Strix Halo unified memory. |

The current Vulkan image was tested with `llama-server --help`: it accepts
`--checkpoint-min-step 256` and rejects the older
`--checkpoint-every-n-tokens` spelling. Older llama.cpp builds documented
`--checkpoint-every-n-tokens` with a default around `8192`, so check the active
image before carrying presets between builds.

## RoPE and Long Context

Leave model defaults unless deliberately extending context. The active presets
keep the previous Qwen3.6 YaRN lines documented in `models-template.ini`, but
comment them out so GGUF metadata controls RoPE by default. Re-enable
`rope-scaling = yarn`, `rope-scale = 8`, and `yarn-orig-ctx = 32768` only for an
explicit long-context comparison. Qwen-family guidance recommends YaRN/RoPE
scaling when going beyond native context; static YaRN can affect short-prompt
behavior, so keep a non-YaRN preset for short-context quality or latency
comparisons.

| Argument | Applies | Meaning |
| --- | --- | --- |
| `--rope-scaling` | both | RoPE scaling method: none, linear, or YaRN. |
| `--rope-scale` | both | Context scaling factor. |
| `--rope-freq-base` | both | Base RoPE frequency override. |
| `--rope-freq-scale` | both | Frequency scale override. |
| `--yarn-orig-ctx` | both | Original training context for YaRN. |
| `--yarn-ext-factor` | both | YaRN extrapolation/interpolation mix. |
| `--yarn-attn-factor` | both | YaRN attention magnitude scaling. |
| `--yarn-beta-slow` | both | YaRN high correction dimension. |
| `--yarn-beta-fast` | both | YaRN low correction dimension. |

## Memory and KV Cache

| Argument | Applies | Meaning |
| --- | --- | --- |
| `-fa`, `--flash-attn` | both | Flash Attention mode. Use on Strix Halo. |
| `-kvo`, `--kv-offload`, `--no-kv-offload` | both | Put KV cache on device when possible. Active Qwen3.6 presets use device KV offload. |
| `-ctk`, `--cache-type-k` | both | KV key datatype. Values accepted by the current image: `f32`, `f16`, `bf16`, `q8_0`, `q4_0`, `q4_1`, `iq4_nl`, `q5_0`, `q5_1`; active Qwen3.6 presets use `q8_0`. |
| `-ctv`, `--cache-type-v` | both | KV value datatype. Values accepted by the current image: `f32`, `f16`, `bf16`, `q8_0`, `q4_0`, `q4_1`, `iq4_nl`, `q5_0`, `q5_1`; active Qwen3.6 presets use `q8_0`. |
| `-dt`, `--defrag-thold` | both | Deprecated KV defrag threshold. |
| `--mlock` | both | Keep model pages resident in RAM. |
| `--mmap`, `--no-mmap` | both | Memory-map model file. Use `--no-mmap` here. |
| `-dio`, `--direct-io`, `--no-direct-io` | both | Use DirectIO when available. |
| `--repack`, `--no-repack` | both | Repack weights for runtime efficiency. |
| `--no-host` | both | Bypass host buffer to allow additional device buffers. |
| `--check-tensors` | both | Validate model tensors during load. Slow diagnostic. |
| `--op-offload`, `--no-op-offload` | both | Offload host tensor operations to device. |
| `-kvu`, `--kv-unified`, `--no-kv-unified` | server | Use one shared KV buffer across slots. Active Qwen3.6 presets enable this. |
| `--cache-idle-slots`, `--no-cache-idle-slots` | server | Save/clear idle slot state. |
| `--cache-prompt`, `--no-cache-prompt` | server | Reuse prompt cache. |
| `--cache-reuse` | server | Minimum chunk size for KV cache reuse. |
| `--slot-save-path` | server | Directory for saving slot KV cache. |

### Parallel Slots and Context

For `llama-server`, `--parallel` is the number of request slots. It is not four
independent full-context model instances. Current upstream docs describe
`--parallel` as server slots, and long-running llama.cpp issue/discussion
threads describe the practical behavior: `--ctx-size` is the total context/KV
pool, and each slot gets roughly `ctx-size / parallel`.

This repo now uses `ctx-size = 262144` and `parallel = 4` in generated presets,
so the expected per-slot budget is about `65536` tokens. If a single request
needs the full 262k budget, use `parallel = 1` or raise `ctx-size` by the slot
count if memory allows. `kv-unified = on` lets slots share one KV buffer, but it
does not make every slot a separate full-size context window.

### KV Cache Quantization

The upstream default for `--cache-type-k` and `--cache-type-v` is `f16`.
`q8_0` halves KV cache memory compared with `f16` and is the least aggressive
quantized KV setting available in normal llama.cpp builds. Community
measurements on Qwen coder models show very small perplexity changes for
`q8_0/q8_0`; `q4_0/q4_0` can be usable but is more likely to show quality loss
at long context or structured-output workloads.

Use `f16/f16` when validating a suspected quality or stability regression. Use
`q8_0/q8_0` when memory headroom matters, especially with `parallel > 1`, long
contexts, MTP, or multiple loaded router models.

### Context Checkpoints

Context checkpoints are restore points for prompt/cache reuse. They matter most
for SWA or hybrid-memory models where llama.cpp cannot always reconstruct an
earlier branch point from only the current KV/cache state. Too few checkpoints
can produce log lines such as `forcing full prompt re-processing due to lack of
cache data`, followed by another full prompt prefill.

For the local VS Code agent harness, the unavoidable first pass is four large
prefills: the main agent plus three subagents each receive full instructions and
context. The checkpoint goal is not to remove those first prefills; it is to
keep follow-up and branched turns from replaying the same 20k+ token prompt.
Local testing showed `ctx-checkpoints = 4` eliminated the observed forced full
reprocesses after the original `ctx-checkpoints = 1`; the active preset now uses
`ctx-checkpoints = 32` because the Strix Halo setup has enough unified memory to
keep more restore points.

## GPU and Offload

| Argument | Applies | Meaning |
| --- | --- | --- |
| `-dev`, `--device` | both | Device list for offload. |
| `-ngl`, `--gpu-layers`, `--n-gpu-layers` | both | Number of layers on GPU/device. |
| `-sm`, `--split-mode` | both | Multi-GPU split mode: none, layer, row, tensor. |
| `-ts`, `--tensor-split` | both | Proportions for multi-GPU split. |
| `-mg`, `--main-gpu` | both | Main GPU index for split modes. |
| `-ot`, `--override-tensor` | both | Force tensor-name patterns to buffer types. |
| `-cmoe`, `--cpu-moe` | both | Keep all MoE weights on CPU. |
| `-ncmoe`, `--n-cpu-moe` | both | Keep first N MoE layers on CPU. |
| `-fit`, `--fit` | both | Let llama.cpp adjust unset knobs to fit memory. |
| `-fitt`, `--fit-target` | both | Device memory margin for `--fit`. |
| `-fitc`, `--fit-ctx` | both | Minimum context size for `--fit`. |

## Model Sources and Adapters

| Argument | Applies | Meaning |
| --- | --- | --- |
| `-m`, `--model` | both | Local GGUF path. |
| `-mu`, `--model-url` | both | Download model from URL. |
| `-dr`, `--docker-repo` | both | Pull model from Docker Hub model repo. |
| `-hf`, `-hfr`, `--hf-repo` | both | Load/download from Hugging Face repo. |
| `-hff`, `--hf-file` | both | Select a specific HF file. |
| `-hfv`, `--hf-repo-v` | both | HF repo for vocoder model. |
| `-hffv`, `--hf-file-v` | both | HF file for vocoder model. |
| `-hft`, `--hf-token` | both | Hugging Face token. Prefer env `HF_TOKEN`. |
| `--offline` | both | Use cache only, no network. |
| `--override-kv` | both | Override GGUF metadata. Advanced/debug only. |
| `--lora` | both | Load LoRA adapter(s). |
| `--lora-scaled` | both | Load LoRA adapter(s) with scale. |
| `--lora-init-without-apply` | server | Load LoRA but apply later via server endpoint. |
| `--control-vector` | both | Load control vector(s). |
| `--control-vector-scaled` | both | Load scaled control vector(s). |
| `--control-vector-layer-range` | both | Layer range for control vectors. |

## Logging

| Argument | Applies | Meaning |
| --- | --- | --- |
| `--log-disable` | both | Disable logs. |
| `--log-file` | both | Write logs to file. |
| `--log-colors` | both | Color logging mode. |
| `-v`, `--verbose`, `--log-verbose` | both | Max verbosity. |
| `-lv`, `--verbosity`, `--log-verbosity` | both | Numeric log threshold. |
| `--log-prefix`, `--no-log-prefix` | both | Include log prefixes. |
| `--log-timestamps`, `--no-log-timestamps` | both | Include timestamps. |

## Sampling and Output Control

These affect token choice after the model has produced logits.

| Argument | Applies | Meaning |
| --- | --- | --- |
| `--samplers` | both | Full ordered sampler chain. |
| `--sampler-seq`, `--sampling-seq` | both | Compact sampler order syntax. |
| `-s`, `--seed` | both | RNG seed. `-1` means random. |
| `--ignore-eos` | both | Continue after EOS. |
| `--temp`, `--temperature` | both | Randomness. Lower is more deterministic. |
| `--top-k` | both | Limit choices to top K tokens. |
| `--top-p` | both | Nucleus sampling probability mass. |
| `--min-p` | both | Drop tokens below relative probability. |
| `--top-nsigma`, `--top-n-sigma` | both | Sigma-based truncation. |
| `--xtc-probability` | both | XTC sampler probability. |
| `--xtc-threshold` | both | XTC threshold. |
| `--typical`, `--typical-p` | both | Locally typical sampling. |
| `--repeat-last-n` | both | Token window for repetition penalty. |
| `--repeat-penalty` | both | Penalize exact repetition. |
| `--presence-penalty` | both | Penalize tokens already present. |
| `--frequency-penalty` | both | Penalize tokens by frequency. |
| `--dry-multiplier` | both | DRY repetition sampler strength. |
| `--dry-base` | both | DRY base value. |
| `--dry-allowed-length` | both | DRY allowed repeated length. |
| `--dry-penalty-last-n` | both | DRY repetition window. |
| `--dry-sequence-breaker` | both | DRY reset sequence(s). |
| `--adaptive-target` | both | Adaptive-p target probability. |
| `--adaptive-decay` | both | Adaptive-p response speed. |
| `--dynatemp-range` | both | Dynamic temperature range. |
| `--dynatemp-exp` | both | Dynamic temperature exponent. |
| `--mirostat` | both | Enable Mirostat mode. |
| `--mirostat-lr` | both | Mirostat learning rate. |
| `--mirostat-ent` | both | Mirostat target entropy. |
| `-l`, `--logit-bias` | both | Bias token IDs up/down. |
| `--grammar` | both | Inline grammar constraint. |
| `--grammar-file` | both | Grammar file. |
| `-j`, `--json-schema` | both | Inline JSON schema constraint. |
| `-jf`, `--json-schema-file` | both | JSON schema file. |
| `-bs`, `--backend-sampling` | both | Experimental backend-side sampling. |

## CLI Prompt and Chat

| Argument | Applies | Meaning |
| --- | --- | --- |
| `-p`, `--prompt` | cli | Initial prompt text. |
| `-f`, `--file` | cli | Prompt file. |
| `-bf`, `--binary-file` | cli | Binary prompt file. |
| `--verbose-prompt` | cli | Print expanded prompt diagnostics. |
| `--display-prompt`, `--no-display-prompt` | cli | Show prompt before generation. |
| `-co`, `--color` | cli | Color terminal output. |
| `-sys`, `--system-prompt` | cli | System prompt. |
| `-sysf`, `--system-prompt-file` | cli | System prompt file. |
| `-r`, `--reverse-prompt` | cli/server | Stop generation when text appears. |
| `-sp`, `--special` | cli/server | Print special tokens. |
| `-cnv`, `--conversation`, `--no-conversation` | cli | Chat/conversation mode. |
| `-st`, `--single-turn` | cli | One chat turn, then exit. |
| `-mli`, `--multiline-input` | cli | Multiline interactive input. |
| `--show-timings`, `--no-show-timings` | cli | Print timing after each response. |
| `--simple-io` | cli | Basic IO for subprocess/limited consoles. |

## Chat Templates and Reasoning

| Argument | Applies | Meaning |
| --- | --- | --- |
| `--jinja`, `--no-jinja` | both | Use Jinja chat template engine. |
| `--chat-template` | both | Built-in or inline chat template. |
| `--chat-template-file` | both | Template file. Useful for `jinja/` experiments. |
| `--chat-template-kwargs` | both | JSON kwargs passed to template parser. Do not use `enable_thinking` here; current llama.cpp warns to use `--reasoning on/off` instead. |
| `--skip-chat-parsing`, `--no-skip-chat-parsing` | both | Disable structured chat parsing. |
| `--reasoning-format` | both | How to expose/extract thinking text. |
| `-rea`, `--reasoning` | both | Enable, disable, or auto-detect reasoning mode. |
| `--reasoning-budget` | both | Token budget for thinking. |
| `--reasoning-budget-message` | both | Message inserted when reasoning budget ends. |
| `--prefill-assistant`, `--no-prefill-assistant` | server | Control assistant-message prefill behavior. |

## Multimodal and Audio

| Argument | Applies | Meaning |
| --- | --- | --- |
| `-mm`, `--mmproj` | both | Multimodal projector path. |
| `-mmu`, `--mmproj-url` | both | Multimodal projector URL. |
| `--mmproj-auto`, `--no-mmproj`, `--no-mmproj-auto` | both | Auto-use projector when available. |
| `--mmproj-offload`, `--no-mmproj-offload` | both | Offload projector to GPU/device. |
| `--image`, `--audio` | cli | Image/audio input files. |
| `--image-min-tokens` | both | Minimum dynamic image tokens. Qwen-VL logs recommend at least `1024` for grounding tasks; active Qwen3.6 presets use `1024`. |
| `--image-max-tokens` | both | Maximum dynamic image tokens. |
| `-mv`, `--model-vocoder` | server | Vocoder model for audio generation. |
| `--tts-use-guide-tokens` | server | Improve TTS word recall. |
| `--media-path` | server | Allow local media via `file://` paths. |

## Server HTTP, API, and Routing

| Argument | Applies | Meaning |
| --- | --- | --- |
| `-lcs`, `--lookup-cache-static` | server | Static lookup cache. |
| `-lcd`, `--lookup-cache-dynamic` | server | Dynamic lookup cache. |
| `--spm-infill` | server | Use Suffix/Prefix/Middle infill order. |
| `--pooling` | server | Embedding pooling mode. |
| `-cb`, `--cont-batching`, `--no-cont-batching` | server | Continuous batching. Usually keep enabled. |
| `-a`, `--alias` | server | API-visible model alias. |
| `--tags` | server | Informational model tags. |
| `--embd-normalize` | server | Embedding normalization. |
| `--host` | server | Listen address. Use `0.0.0.0` in containers. |
| `--port` | server | Listen port. |
| `--reuse-port` | server | Allow multiple sockets on same port. |
| `--path` | server | Static file path. |
| `--api-prefix` | server | Prefix all routes. |
| `--ui`, `--no-ui` | server | Enable built-in UI. |
| `--ui-config` | server | Inline UI preferences JSON. |
| `--ui-config-file` | server | UI preferences file. |
| `--ui-mcp-proxy`, `--no-ui-mcp-proxy` | server | Experimental MCP proxy. Do not expose untrusted. |
| `--tools` | server | Built-in agent tools. Treat as high-risk if exposed. |
| `--embedding`, `--embeddings` | server | Embedding-only server mode. |
| `--rerank`, `--reranking` | server | Enable reranking endpoint. |
| `--api-key` | server | API key(s). |
| `--api-key-file` | server | API key file. |
| `--ssl-key-file` | server | TLS private key. |
| `--ssl-cert-file` | server | TLS certificate. |
| `-to`, `--timeout` | server | HTTP read/write timeout. |
| `--threads-http` | server | HTTP worker threads. |
| `--metrics` | server | Prometheus metrics endpoint. |
| `--props` | server | Enable mutable global props endpoint. |
| `--slots`, `--no-slots` | server | Slot monitoring endpoint. |
| `--models-dir` | server | Directory for router model discovery. |
| `--models-preset` | server | INI model router presets. |
| `--models-max` | server | Max simultaneously loaded router models. |
| `--models-autoload`, `--no-models-autoload` | server | Auto-load router models on request. |
| `-sps`, `--slot-prompt-similarity` | server | Slot reuse similarity threshold. |
| `--sleep-idle-seconds` | server | Unload/sleep after idle period. |
| `--webui*` | server | Deprecated aliases for `--ui*`. Avoid in new work. |

## Speculative Decoding

For this repo, the important split is:

- MTP: `--spec-type draft-mtp --spec-draft-n-max N`
- MTP plus n-gram map: `--spec-type draft-mtp --spec-draft-n-max N --spec-type ngram-map-k4v --spec-ngram-map-k4v-size-n 16 --spec-ngram-map-k4v-size-m 24 --spec-ngram-map-k4v-min-hits 2`
- Draft model: `--spec-type draft-simple --model-draft path`
- N-gram: `--spec-type ngram-*`

The Crown Halo dynamic MTP preset uses pure native MTP from the model card,
without the repo's generic n-gram sidecar settings.

| Argument | Applies | Meaning |
| --- | --- | --- |
| `--spec-type` | both | Speculation method(s). |
| `--spec-default` | both | Use llama.cpp default speculation config. |
| `--spec-draft-model`, `-md`, `--model-draft` | both | Draft model path. |
| `--spec-draft-hf`, `--hf-repo-draft` | both | Draft model from Hugging Face. |
| `--spec-draft-n-max` | both | Max draft tokens. Main MTP knob. |
| `--spec-draft-n-min` | both | Minimum draft tokens. |
| `--spec-draft-p-split`, `--draft-p-split` | both | Split probability. |
| `--spec-draft-p-min`, `--draft-p-min` | both | Minimum acceptance/probability threshold. |
| `--spec-draft-ngl`, `--n-gpu-layers-draft` | both | GPU layers for draft model. |
| `--spec-draft-device`, `--device-draft` | both | Device list for draft model. |
| `--spec-draft-type-k`, `--cache-type-k-draft` | both | Draft/MTP KV key datatype. Upstream default is `f16`; active generated MTP presets use `q8_0`. |
| `--spec-draft-type-v`, `--cache-type-v-draft` | both | Draft/MTP KV value datatype. Upstream default is `f16`; active generated MTP presets use `q8_0`. |
| `--spec-draft-threads`, `--threads-draft` | both | Draft generation threads. |
| `--spec-draft-threads-batch`, `--threads-batch-draft` | both | Draft batch threads. |
| `--spec-draft-cpu-mask`, `--cpu-mask-draft` | both | Draft CPU affinity. |
| `--spec-draft-cpu-range`, `--cpu-range-draft` | both | Draft CPU range. |
| `--spec-draft-cpu-strict`, `--cpu-strict-draft` | both | Strict draft CPU placement. |
| `--spec-draft-prio`, `--prio-draft` | both | Draft priority. |
| `--spec-draft-poll`, `--poll-draft` | both | Draft polling. |
| `--spec-draft-cpu-mask-batch`, `--cpu-mask-batch-draft` | both | Draft batch CPU mask. |
| `--spec-draft-cpu-strict-batch` | both | Strict draft batch placement. |
| `--spec-draft-prio-batch`, `--prio-batch-draft` | both | Draft batch priority. |
| `--spec-draft-poll-batch`, `--poll-batch-draft` | both | Draft batch polling. |
| `--spec-draft-override-tensor`, `--override-tensor-draft` | both | Draft tensor placement overrides. |
| `--spec-draft-cpu-moe`, `--cpu-moe-draft` | both | Keep draft MoE weights on CPU. |
| `--spec-draft-n-cpu-moe`, `--n-cpu-moe-draft` | both | Keep first N draft MoE layers on CPU. |
| `--spec-ngram-mod-n-min` | server | N-gram mod minimum draft tokens. |
| `--spec-ngram-mod-n-max` | server | N-gram mod maximum draft tokens. |
| `--spec-ngram-mod-n-match` | server | N-gram mod lookup length. |
| `--spec-ngram-simple-size-n` | server | N-gram simple lookup length. |
| `--spec-ngram-simple-size-m` | server | N-gram simple draft length. |
| `--spec-ngram-simple-min-hits` | server | N-gram simple minimum hits. |
| `--spec-ngram-map-k-size-n` | server | N-gram map-k lookup length. |
| `--spec-ngram-map-k-size-m` | server | N-gram map-k draft length. |
| `--spec-ngram-map-k-min-hits` | server | N-gram map-k minimum hits. |
| `--spec-ngram-map-k4v-size-n` | server | N-gram map-k4v lookup length. |
| `--spec-ngram-map-k4v-size-m` | server | N-gram map-k4v draft length. |
| `--spec-ngram-map-k4v-min-hits` | server | N-gram map-k4v minimum hits. |
| `--draft`, `--draft-n`, `--draft-max` | both | Removed alias. Use `--spec-draft-n-max` or n-gram equivalent. |
| `--draft-min`, `--draft-n-min` | both | Removed alias. Use `--spec-draft-n-min` or n-gram equivalent. |
| `--spec-ngram-size-n` | server | Removed alias. Use method-specific n-gram size. |
| `--spec-ngram-size-m` | server | Removed alias. Use method-specific n-gram size. |
| `--spec-ngram-min-hits` | server | Removed alias. Use method-specific min hits. |

`--cache-type-k` and `--cache-type-v` configure the main model's KV cache.
`--spec-draft-type-k` and `--spec-draft-type-v` configure only the speculative
draft path, which includes the internal MTP draft layer when using
`--spec-type draft-mtp` and the separate draft model when using
`--spec-type draft-simple --model-draft ...`. They are not aliases for the main
KV cache flags. Quantizing both to `q8_0` keeps the main and draft caches on the
same conservative quantized setting while preserving `f16` as the upstream
default comparison point.

## Built-In Download Presets

These may download weights from the internet. Prefer explicit `-hf`/`-m` in
reproducible container workflows.

| Argument | Applies | Meaning |
| --- | --- | --- |
| `--embd-gemma-default` | server | Default EmbeddingGemma model. |
| `--fim-qwen-1.5b-default` | server | Default Qwen Coder 1.5B FIM model. |
| `--fim-qwen-3b-default` | server | Default Qwen Coder 3B FIM model. |
| `--fim-qwen-7b-default` | server | Default Qwen Coder 7B FIM model. |
| `--fim-qwen-7b-spec` | server | Qwen Coder 7B plus draft model. |
| `--fim-qwen-14b-spec` | server | Qwen Coder 14B plus draft model. |
| `--fim-qwen-30b-default` | server | Default Qwen 3 Coder 30B A3B model. |
| `--gpt-oss-20b-default` | both | Default gpt-oss-20b model. |
| `--gpt-oss-120b-default` | both | Default gpt-oss-120b model. |
| `--vision-gemma-4b-default` | both | Default Gemma 3 4B vision model. |
| `--vision-gemma-12b-default` | both | Default Gemma 3 12B vision model. |

## Suggested Profiles

### Reliable Server Baseline

```bash
llama-server \
  -m /models/model.gguf \
  --host 0.0.0.0 \
  --port 8080 \
  -c 131072 \
  -b 2048 \
  -ub 2048 \
  -ngl 999 \
  -fa 1 \
  --no-mmap
```

Use `-ub 512` for Vulkan RADV/AMDVLK.

### Long Context Experiment

```bash
llama-server \
  -m /models/model.gguf \
  --host 0.0.0.0 \
  -c 65536 \
  -b 2048 \
  -ub 1024 \
  -ngl 999 \
  -fa 1 \
  --no-mmap
```

Raise `-c` first, then tune `-ub` down if memory pressure or crashes appear.

### MTP Experiment

```bash
llama-server \
  -m /models/model.gguf \
  --host 0.0.0.0 \
  -c 131072 \
  -b 2048 \
  -ub 2048 \
  -ngl 999 \
  -fa 1 \
  --no-mmap \
  --spec-type draft-mtp \
  --spec-draft-n-max 3 \
  --spec-type ngram-map-k4v \
  --spec-ngram-map-k4v-size-n 16 \
  --spec-ngram-map-k4v-size-m 24 \
  --spec-ngram-map-k4v-min-hits 2 \
  -np 1
```

Compare `--spec-draft-n-max 2` and `3`; larger is not automatically faster.

### Deterministic Debugging

```bash
llama-cli \
  -m /models/model.gguf \
  -p "Test prompt" \
  -c 8192 \
  -ngl 999 \
  -fa 1 \
  --no-mmap \
  --temp 0 \
  -s 1
```

## Decision Checklist

1. Choose backend: ROCm for throughput, Vulkan RADV for compatibility.
2. Choose model source: local `-m` for reproducibility, `-hf` for convenience.
3. Set required Strix Halo flags: `-fa 1 --no-mmap`.
4. Set context: `-c 131072`, then increase only after memory estimate.
5. Set batch: `-b 2048`, tune `-ub` per backend.
6. Decide server slots: keep `-np 1` for largest models; raise only for smaller ones.
7. Decide chat template: default metadata first; use `--chat-template-file` for local Jinja experiments.
8. Decide sampling: defaults first; change `--temp`, `--top-p`, `--min-p`, penalties only with a test prompt set.
9. Decide speculation: benchmark baseline before enabling MTP/draft/ngram.
