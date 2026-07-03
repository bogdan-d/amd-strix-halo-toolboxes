# Podman Runtime

Run the images directly with Podman through `bin/run.sh`, which mounts the ROCm
and Vulkan runtime images with the correct devices and the Strix Halo defaults.

## Backends

The helper script supports the local images:

| Backend | Image | GPU devices |
| :--- | :--- | :--- |
| `rocm` | `localhost/strix-llama:rocm` by default, or `:rocm-$CPU_TARGET` when `CPU_TARGET!=generic` | `/dev/dri`, `/dev/kfd` |
| `rocm-7.2.4` | `localhost/strix-llama:rocm-7.2.4` by default, or `:rocm-7.2.4-$CPU_TARGET` when `CPU_TARGET!=generic` | `/dev/dri`, `/dev/kfd` |
| `rocm-next` | `localhost/strix-llama:rocm-next` by default, or `:rocm-next-$CPU_TARGET` when `CPU_TARGET!=generic` | `/dev/dri`, `/dev/kfd` |
| `rocm7-nightlies` | `localhost/strix-llama:rocm7-nightlies` by default, or `:rocm7-nightlies-$CPU_TARGET` when `CPU_TARGET!=generic` | `/dev/dri`, `/dev/kfd` |
| `vulkan` | `localhost/strix-llama:vulkan` by default, or `:vulkan-$CPU_TARGET` when `CPU_TARGET!=generic` | `/dev/dri` |
| `vulkan-fpx` | `localhost/strix-llama:vulkan-fpx` by default, or `:vulkan-fpx-$CPU_TARGET` when `CPU_TARGET!=generic` | `/dev/dri` |
| `rocm-fpx` | `localhost/strix-llama:rocm-fpx` by default, or `:rocm-fpx-$CPU_TARGET` when `CPU_TARGET!=generic` | `/dev/dri`, `/dev/kfd` |
| `rocm-next-fpx` | `localhost/strix-llama:rocm-next-fpx` by default, or `:rocm-next-fpx-$CPU_TARGET` when `CPU_TARGET!=generic` | `/dev/dri`, `/dev/kfd` |

`vulkan-radv` and `vulkan_radv` are aliases for `vulkan`. Explicit tags created
by `bin/build.sh` also work directly, for example `rocm-strix-halo`,
`rocm-7.2.4-strix-halo`, `rocm-next-native`, `vulkan-fpx-strix-halo`,
`rocm-fpx-strix-halo`, `rocm-next-fpx-strix-halo`, or `vulkan-native`.

## Quick Start

Put models under `~/models`, or point `MODELS_DIR` at your model directory:

```bash
export MODELS_DIR=/var/mnt/xdata/models
```

Check GPU visibility:

```bash
bin/run.sh rocm list-devices
CPU_TARGET=strix-halo bin/run.sh rocm list-devices
bin/run.sh vulkan list-devices
```

For ROCm backends, a silent exit or exit status `139` means the process likely
segfaulted before llama.cpp could print an error. Check the runtime first:

```bash
bin/run.sh rocm-next-fpx run rocminfo
bin/run.sh rocm-next-fpx list-devices
```

`bin/run.sh` uses same `CPU_TARGET` and `ROCM_VERSION` defaults as
`bin/build.sh`, so non-generic image variants built with `CPU_TARGET=strix-halo`
or `CPU_TARGET=native` can be run without spelling full tag each time:

```bash
CPU_TARGET=strix-halo bin/run.sh rocm server
CPU_TARGET=strix-halo bin/run.sh rocm-7.2.4 server
CPU_TARGET=strix-halo bin/run.sh vulkan-fpx server
CPU_TARGET=strix-halo bin/run.sh rocm-fpx server
CPU_TARGET=strix-halo bin/run.sh rocm-next-fpx server
CPU_TARGET=native bin/run.sh vulkan list-devices
```

Those commands resolve to `:rocm-strix-halo`, `:rocm-7.2.4-strix-halo`, and
`:vulkan-fpx-strix-halo`, `:rocm-fpx-strix-halo`,
`:rocm-next-fpx-strix-halo`, and `:vulkan-native`. You can also pass exact
build tag as backend argument if you want to bypass env-based resolution.

List the configured model IDs:

```bash
bin/run.sh rocm models
```

Start `llama-server` with the active model preset:

```bash
bin/run.sh rocm server
```

The default preset is generated on the host from the tracked
`models-template.ini` and the GGUF files under `MODELS_DIR`. `bin/run.sh` writes
that active preset to a temporary file, mounts it read-only into the container as
`/tmp/llama-models.ini`, and passes it to llama.cpp as `--models-preset`; it
does not write `models.ini` into the mounted model directory.

Discovery exposes every non-`mmproj` `*.gguf` file. Generated names use
`author/model-file-stem` when the mounted path has that shape, for example
`unsloth/Qwen3.6-27B-MTP-UD-Q4_K_XL`. A single same-directory
`mmproj*.gguf` is paired automatically; multiple projectors are ignored with a
warning. Paths or filenames containing `MTP` or `mtp` get the local MTP
speculation settings. Qwen-derived models also get a `~non-reasoning` variant.

The generated Qwen3.6 presets use `ctx-size = 262144` as the total server
context pool, `parallel = 4`, `q8_0` KV cache, device KV offload, unified KV,
`ctx-checkpoints = 32`, `checkpoint-min-step = 256`, prompt caching with
`cache-ram = 32768`, `image-min-tokens = 1024`, `reasoning = on`, and
provider-qualified model names. That means each slot gets about 65536 tokens
before any llama.cpp auto-sizing or model-limit behavior.
`bin/run.sh` supplies backend-specific
`batch-size` and `ubatch-size` values on the preset server command line so ROCm
can use larger prefill microbatches without making the shared preset unsafe for
Vulkan. `parallel > 1` splits `ctx-size` across server slots unless `ctx-size`
is raised accordingly. Clients select models by preset name:

The current image accepts `--checkpoint-min-step` and rejects the older
`--checkpoint-every-n-tokens` flag. The checkpoint defaults are tuned for
agentic 4-slot runs where the first full prompt prefill per slot is unavoidable,
but follow-up turns should restore from checkpoints rather than replaying the
same long prompt.

```bash
curl http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "unsloth/Qwen3.6-27B-MTP-UD-Q4_K_XL",
    "messages": [{"role": "user", "content": "Write a short Rust CLI plan."}]
  }'
```

When a model path or filename contains `MTP`/`mtp`, generated presets include a
plain non-speculative route and a separate `~mtp` route with draft-MTP
speculation enabled:

```json
"model": "unsloth/Qwen3.6-27B-MTP-UD-Q4_K_XL~mtp"
```

ROCmFPX-compatible GGUFs use the ROCmFPX fork backend matrix:

```bash
bin/build.sh vulkan-fpx
bin/run.sh vulkan-fpx list-devices

bin/build.sh rocm-fpx
bin/run.sh rocm-fpx list-devices

bin/build.sh rocm-next-fpx
bin/run.sh rocm-next-fpx list-devices
```

For those backends, `bin/run.sh` automatically generates an FPX-only preset.
For the ROCm FPX backends it also sets
`HSA_OVERRIDE_GFX_VERSION=11.5.1` plus `GGML_HIP_ENABLE_UNIFIED_MEMORY=1`.
Normal generated presets skip ROCmFPX-compatible GGUFs so stock images do not
expose routes that cannot load. The fork profile emits reasoning-enabled routes
per compatible model; pass `--with-non-reasoning` to add matching
non-reasoning routes.
Only models identified as MTP-capable get `~mtp` route IDs, `[MTP]` aliases,
and `draft-mtp` flags; MTP-capable files also keep non-speculative base routes.
Generated IDs use `author/model-file-stem`, plus route suffixes such as `~mtp`,
`~vision`, and `~non-reasoning`. Suffixes are joined with `~` rather than `:`
because llama.cpp's preset loader canonicalizes the tag after a `:` — it
uppercases it and can drop a segment (`:non-reasoning` would become `:REASONING`
and collide with `:mtp:non-reasoning`); with no `:` the id is preserved verbatim
and matches across the stock and fork builds
([ggml-org/llama.cpp#25150](https://github.com/ggml-org/llama.cpp/issues/25150)).
Generated aliases use one display pattern:
`[author] model-name [weights / active-weights] [quant] [route/features] [disk-size]`,
for example
`[bartowski] allura-org_Qwen3.6-Anko [35B / A3B] [Q6_K_L] [VISION] [29G]`
or
`[plunderstruck] Qwen3.6-STRIX-embF16-imatrix-headQ6 [27B] [MTP] [UNC] [FP4] [16G]`.
FPX routes share the global `[*]` defaults (262144 context, `threads = 16`,
`b2048`, f16 main KV, `cache-reuse = 256`, 32 context checkpoints,
`cache-ram = 65536`, `metrics` on, `mmap` off, and the base
`chat-template-kwargs = {"preserve_thinking": true}`) and only override what
differs in the model section: DeepSeek reasoning format for the reasoning-on
route. `bin/run.sh` pins every route to a single device via `--device`
(`Vulkan0` for vulkan backends, `ROCm0` for ROCm); ROCm device sections emit
`u256` (the ROCm microbatch limit), while Vulkan inherits `1024` from `[*]`.
MTP-capable routes add `draft-mtp` depth 5 with f16 draft KV (MoE models use
depth 2). The fork rejects `checkpoint-min-step` inside model preset sections,
so generated ROCmFPX presets omit it even though some model cards show
`-cpent 256` in direct command examples. Existing ROCmFP4-named model configs
remain accepted by the ROCmFPX generator and use this same profile. When
`--with-vision` is used and a same-directory `mmproj-F32.gguf` exists, the
generated vision routes add `mmproj` and `image-min-tokens = 1024`.
`Qwopus3.6-27B-Coder-MTP-ROCmFP4-GGUF` keeps those runtime flags but follows
its model card's agentic-use guidance by overriding the global kwargs with
`chat-template-kwargs = {"enable_thinking": false, "preserve_thinking": true}`
with DeepSeek reasoning formatting.
`Nex-N2-mini-ROCmFP4-GGUF` is not an MTP model. Its generated ROCmFPX route
uses the same Strix runtime/cache profile, but `ctx-size = 131072`, no
`spec-*` flags, and the same generated display-alias pattern.

`jcbtc/qwen3.6-35b-a3b-crown-halo-mtp-dynamic` is a special-case Strix Halo
MTP profile. The generator always emits exactly two routes for it, regardless
of `--with-non-reasoning`: `~mtp` with reasoning enabled and
`~mtp~non-reasoning` with reasoning disabled. Both routes keep the model-card
profile in the model section itself: 131072 context, row split, `f16/f16` main
and draft KV, `draft-mtp` depth 2, single-slot serving, Strix polling, and
`b2048/u512`. The routes use the shared generated display-alias pattern, for example
`[jcbtc] Qwen3.6-HaloStrix-Dyn-v7 [35B / A3B] [MTP] [21G]` and
`[jcbtc] Qwen3.6-HaloStrix-Dyn-v7 [35B / A3B] [MTP] [NO-THINK] [21G]`,
so the router can load both presets without alias collisions.

Generated presets are text-only by default, even when a same-directory
`mmproj*.gguf` file exists. Pass `--with-vision` before the backend to add
separate `~vision` model IDs with `mmproj` wired in:

```bash
bin/run.sh --with-vision rocm models
bin/run.sh --with-vision rocm server
```

For Qwen/Qwen-derived models, pass `--with-non-reasoning` before the backend to
add `~non-reasoning` variants that use `reasoning = off` and the non-thinking
sampling defaults from the Unsloth Qwen3.6 guidance. For example:

```bash
bin/run.sh --with-non-reasoning rocm models
bin/run.sh --with-non-reasoning rocm server
```

```json
"model": "unsloth/Qwen3.6-27B-MTP-UD-Q4_K_XL~non-reasoning"
```

The flags can be combined. A Qwen vision preset then also gets
`~vision~non-reasoning`, and an MTP-capable Qwen vision preset gets
`~vision~mtp` and `~vision~mtp~non-reasoning` siblings.

Use `LLAMA_MODELS_PRESET` to skip generation and point at an explicit preset
under `MODELS_DIR`:

```bash
LLAMA_MODELS_PRESET=/var/mnt/xdata/models/models-sample-2.ini \
  bin/run.sh rocm server
```

`models-template.ini` uses llama.cpp's documented `[*]` global section to keep
shared defaults in one place. The current server build may also expose that
global section as a routeable `default` model. Treat that as a router artifact:
do not request `model = "default"`, because it has no model path and fails to
load.

In router mode, `llama-server` applies preset values in this order:

1. Command-line arguments passed to `llama-server`
2. Model-specific options in the selected preset section
3. Global options in the preset file's `[*]` section

`bin/run.sh` intentionally uses that precedence for backend-specific batch
defaults. Its command-line `--batch-size` and `--ubatch-size` values override
the shared fallback values from `models-template.ini`, letting ROCm use larger
microbatches while keeping the preset file usable for raw/manual Vulkan runs.

Refresh local coding-tool configs from the same generated preset used by a
server run:

```bash
bin/run.sh --with-non-reasoning --with-vision --with-configs rocm server
```

Set `UPDATE_CONFIGS=1` in `.env` or the environment to also merge those
generated configs into existing user config files automatically after
`--with-configs` refreshes `coding-tool-configs/`:

```bash
UPDATE_CONFIGS=1 bin/run.sh --with-non-reasoning --with-vision --with-configs rocm server
```

The same flag works when saving a generated preset directly:

```bash
bin/generate-models-preset.sh --with-non-reasoning --with-vision --with-configs \
  "$MODELS_DIR" /root/models models-template.ini /tmp/llama-models.ini
```

For the ROCmFPX custom backends, use `--rocmfpx-only` directly, or let
`bin/run.sh` add it for the `*-fpx` backends:

```bash
bin/generate-models-preset.sh --rocmfpx-only --device ROCm0 \
  "$MODELS_DIR" /root/models models-template.ini /tmp/llama-models-rocmfpx.ini
```

The generator writes:

- `coding-tool-configs/kilocode/kilo.jsonc`
- `coding-tool-configs/opencode/opencode.jsonc`
- `coding-tool-configs/vscode/chatLanguageModels.json`

Which targets are emitted is declared in the
`coding-tool-configs.manifest.json` manifest at the repo root. The `pi` target
is listed there but disabled (`"enabled": false`), so
`coding-tool-configs/pi/models.json` is not regenerated; its builder is retained
and the target is re-enabled by flipping the flag in the manifest. On each run
the generator also prunes stale outputs left over from a previously enabled
target (the file plus any directories it leaves empty), so `coding-tool-configs/`
stays consistent with the manifest. Point the generator at another manifest with
`--manifest <path>`.

Apply those generated configs to existing user config files manually with:

```bash
bin/update-user-configs.ts
```

The copy script skips tools whose user config file does not already exist, and
it honors the same `coding-tool-configs.manifest.json` manifest: a target
disabled there is never merged into its user config, even if a stale generated
file remains from a previous run. By default it therefore updates VS Code, VS
Code Insiders, Kilo Code, and OpenCode, and skips the disabled Pi target; for
OpenCode it prefers `~/.config/opencode/opencode.jsonc`, then falls back to
`~/.config/opencode/opencode.json`. Use `--base-home <dir>` to test against a
temporary home-shaped directory without touching real user configs.

It reads model IDs, display aliases, and inherited `ctx-size` / `parallel`
values from the llama.cpp preset. Coding-tool config IDs stay equal to the
preset section names; a section's `alias`, when present, is used only as the
display name. The generator then reports the per-slot context as
`floor(ctx-size / parallel)`. Sections with `mmproj = ...` or a `~vision`
suffix advertise image input; other sections stay text-only. `reasoning = off`
sections are emitted as non-thinking/non-reasoning models, and explicit `~mtp`
sections are tagged as MTP models. The default output
budget is `32768`, which matches the Qwen3.6 guidance used by this repo, but
per-slot contexts below `100000` tokens are capped to `16384` output tokens.
Override the normal output budget with `--max-output-tokens` if a later model
card or local run needs a different limit. For VS Code only, the script emits
`maxInputTokens` as `per-slot context - maxOutputTokens` because that IDE treats
the two fields as the full model context when added together.

Check model-load without leaving a server running:

```bash
bin/run.sh rocm load-test \
  /var/mnt/xdata/models/qwen/model.gguf
```

`load-test` uses the same server defaults, adds `--no-warmup`, disables the
server UI and prompt cache, waits for the model-loaded log line, then stops the
container. Increase `LLAMA_LOAD_TEST_TIMEOUT` for large models.

Direct model paths are still supported for one-off runs:

```bash
bin/run.sh rocm server \
  /var/mnt/xdata/models/qwen/model.gguf
```

## Local Builds

Use `bin/build.sh` to build images from `containers/Containerfile`.
See [build.md](build.md) for build targets and smoke tests.

Start `llama-server` with draft MTP enabled:

```bash
bin/run.sh rocm mtp-server \
  /var/mnt/xdata/models/qwen-mtp/model.gguf \
  3
```

The `3` means `--spec-draft-n-max 3`. Use `2` for MTP-2. The default can also
come from `LLAMA_SPEC_DRAFT_N_MAX`; `LLAMA_SPEC_DRAFT_P_MIN` adds
`--spec-draft-p-min`, and `LLAMA_MTP_NGRAM=0` disables the helper's
`ngram-map-k4v` sidecar so the run uses pure native MTP.

Reddit-style Qwen3.6 27B Q6_K comparison profile, adapted to this helper:

```bash
LLAMA_CONTEXT=196608 \
LLAMA_BATCH=512 \
LLAMA_UBATCH=512 \
LLAMA_SPEC_DRAFT_N_MAX=10 \
LLAMA_SPEC_DRAFT_P_MIN=0.5 \
LLAMA_MTP_NGRAM=0 \
bin/run.sh vulkan mtp-server \
  /var/mnt/xdata/models/Qwen3.6-27B-MTP-Q6_K.gguf \
  --cache-ram 32768 \
  --ctx-checkpoints 8 \
  --checkpoint-min-step 256 \
  -ctk q8_0 -ctv q8_0 --kv-unified \
  --reasoning on --reasoning-budget 16384 \
  --temp 0.6 --top-k 20 --top-p 0.95 --min-p 0.0 \
  --presence-penalty 0.0 --repeat-penalty 1.0 \
  --metrics --perf
```

Use this as an experiment, not a default: the source report was CUDA/RTX 5090
specific, single-slot (`--parallel 1`), and VRAM-limited. ROCmFPX currently does
not expose `--checkpoint-min-step`; omit that flag for `*-fpx` runs unless the
fork grows support.

The server listens on port `8080` by default. Override it with:

```bash
LLAMA_PORT=8081 bin/run.sh vulkan server
```

Run `llama-cli`:

```bash
bin/run.sh rocm cli \
  /var/mnt/xdata/models/qwen/model.gguf \
  -p "Write a Strix Halo toolkit haiku."
```

Run `llama-bench`:

```bash
bin/run.sh vulkan bench \
  /var/mnt/xdata/models/qwen/model.gguf
```

## Strix Halo Defaults

The helper applies the defaults used by the benchmark scripts for this iGPU:

| Setting | Default | Source / reason |
| :--- | :--- | :--- |
| `-fa 1` | enabled | Required for reliable Strix Halo runs and used in all local benchmarks. |
| `--no-mmap` | enabled for server/CLI | Avoids mmap-related memory fragmentation and crashes. |
| `-ngl` | `999` for server/CLI, `99` for bench | Full GPU offload, matching the benchmark scripts for `llama-bench`. |
| `-c` / bench `-d` | `131072` | Long-context benchmark baseline. |
| `-b` / bench `-p` Vulkan | `2048` | Conservative Vulkan prompt batch baseline. |
| `-b` / bench `-p` ROCm | `4096` | Matches the observed Strix Halo ROCm guidance of keeping logical batch at least 2x the 2048 physical microbatch. |
| `-ub` Vulkan | `512` | Vulkan long-context benchmark setting. |
| `-ub` ROCm | `2048` | ROCm long-context benchmark setting and current prefill saturation target. |
| `GGML_HIP_MAX_BATCH_SIZE` ROCm | `2048` | Keeps the HIP backend batch cap aligned with the ROCm microbatch default. |
| `-mmp 0` | enabled for bench | Benchmark mmap-off equivalent. |

Generated presets inherit the shared `models-template.ini` context and RoPE
defaults unless a model-specific route overrides them. The Crown Halo dynamic
MTP route overrides the direct-run context baseline with the model-card
recommendation, `ctx-size = 131072`, and keeps `batch-size = 2048` /
`ubatch-size = 512` in the model section so router runs match the Vulkan MTP
profile even when `bin/run.sh` would normally pass backend batch defaults.

Override these with environment variables:

```bash
LLAMA_CONTEXT=65536 LLAMA_UBATCH=512 bin/run.sh vulkan server \
  /var/mnt/xdata/models/qwen/model.gguf
```

Or pass llama.cpp flags at the end; trailing flags are preserved:

```bash
bin/run.sh rocm server \
  /var/mnt/xdata/models/qwen/model.gguf \
  -c 8192 -ub 1024
```

## Raw Podman Commands

The helper expands to commands like these.

Vulkan:

```bash
podman run --rm -it \
  --security-opt seccomp=unconfined \
  --security-opt label=disable \
  --group-add keep-groups \
  --ipc=host \
  --device /dev/dri \
  -v /var/mnt/xdata/models:/root/models \
  -v /tmp/llama-models.ini:/tmp/llama-models.ini:ro \
  -p 8080:8080 \
  localhost/strix-llama:vulkan \
  llama-server --models-preset /tmp/llama-models.ini --models-max 1 \
    --host 0.0.0.0 --port 8080 \
    --batch-size 2048 --ubatch-size 512
```

ROCm:

```bash
podman run --rm -it \
  --security-opt seccomp=unconfined \
  --security-opt label=disable \
  --group-add keep-groups \
  --ipc=host \
  --device /dev/dri \
  --device /dev/kfd \
  -e GGML_HIP_MAX_BATCH_SIZE=2048 \
  -v /var/mnt/xdata/models:/root/models \
  -v /tmp/llama-models.ini:/tmp/llama-models.ini:ro \
  -p 8080:8080 \
  localhost/strix-llama:rocm \
  llama-server --models-preset /tmp/llama-models.ini --models-max 1 \
    --host 0.0.0.0 --port 8080 \
    --batch-size 4096 --ubatch-size 2048
```

Use the image tags in the backend table to switch between setups.

MTP Vulkan:

```bash
podman run --rm -it \
  --security-opt seccomp=unconfined \
  --security-opt label=disable \
  --group-add keep-groups \
  --ipc=host \
  --device /dev/dri \
  -v /var/mnt/xdata/models:/root/models \
  -p 8080:8080 \
  localhost/strix-llama:vulkan \
  llama-server -m /root/models/qwen-mtp/model.gguf --host 0.0.0.0 --port 8080 \
    -c 131072 -b 2048 -ub 512 -ngl 999 -fa 1 --no-mmap \
    --spec-type draft-mtp --spec-draft-n-max 3 \
    --spec-type ngram-map-k4v \
    --spec-ngram-map-k4v-size-n 16 \
    --spec-ngram-map-k4v-size-m 24 \
    --spec-ngram-map-k4v-min-hits 2 \
    -np 1
```

## Notes

The helper always adds `-fa 1` and `--no-mmap` for direct-model `server`, `mtp-server`, `load-test`, and `cli` because those are required for reliable Strix Halo runs. Preset `server` takes those settings from the generated preset based on `models-template.ini`, unless `LLAMA_MODELS_PRESET` points at an explicit preset. Generated presets omit stock Qwen `~non-reasoning` variants, ROCmFPX `~non-reasoning` variants, and mmproj-backed `~vision` variants unless `bin/run.sh` is called with `--with-non-reasoning` or `--with-vision`. For `bench`, it uses `-fa 1`, `-mmp 0`, `-p 2048`, `-n 32`, `-d 131072`, and the backend-specific `-ub` value.

The preset passed to `server` and the model path passed to `server`, `mtp-server`, `load-test`, `cli`, or `bench` must be under `MODELS_DIR`, because only that directory is mounted into the container.
