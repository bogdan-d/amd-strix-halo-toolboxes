# Podman without Toolbx or Distrobox

You can run the published images directly with Podman. This avoids creating Toolbx/Distrobox containers while keeping the same ROCm and Vulkan runtime images.

## Backends

The helper script supports the local next-workflow images:

| Backend | Image | GPU devices |
| :--- | :--- | :--- |
| `rocm` | `localhost/amd-strix-halo-toolboxes:rocm` by default, or `:rocm-$CPU_TARGET` when `CPU_TARGET!=generic` | `/dev/dri`, `/dev/kfd` |
| `rocm-7.2.4` | `localhost/amd-strix-halo-toolboxes:rocm-7.2.4` by default, or `:rocm-7.2.4-$CPU_TARGET` when `CPU_TARGET!=generic` | `/dev/dri`, `/dev/kfd` |
| `rocm-next` | `localhost/amd-strix-halo-toolboxes:rocm-next` by default, or `:rocm-next-$CPU_TARGET` when `CPU_TARGET!=generic` | `/dev/dri`, `/dev/kfd` |
| `rocm7-nightlies` | `localhost/amd-strix-halo-toolboxes:rocm7-nightlies` by default, or `:rocm7-nightlies-$CPU_TARGET` when `CPU_TARGET!=generic` | `/dev/dri`, `/dev/kfd` |
| `vulkan` | `localhost/amd-strix-halo-toolboxes:vulkan` by default, or `:vulkan-$CPU_TARGET` when `CPU_TARGET!=generic` | `/dev/dri` |

`vulkan-radv` and `vulkan_radv` are aliases for `vulkan`. Explicit tags created
by `bin/build.sh` also work directly, for example `rocm-strix-halo`,
`rocm-7.2.4-strix-halo`, `rocm-next-native`, or `vulkan-native`.

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

`bin/run.sh` uses same `CPU_TARGET` and `ROCM_VERSION` defaults as
`bin/build.sh`, so non-generic image variants built with `CPU_TARGET=strix-halo`
or `CPU_TARGET=native` can be run without spelling full tag each time:

```bash
CPU_TARGET=strix-halo bin/run.sh rocm server
CPU_TARGET=strix-halo bin/run.sh rocm-7.2.4 server
CPU_TARGET=native bin/run.sh vulkan list-devices
```

Those commands resolve to `:rocm-strix-halo`, `:rocm-7.2.4-strix-halo`, and
`:vulkan-native`. You can also pass exact build tag as backend argument if you
want to bypass env-based resolution.

List the configured model IDs:

```bash
bin/run.sh rocm models
```

Start `llama-server` with the active model preset:

```bash
bin/run.sh rocm server
```

The default preset is `models/models.ini`, mounted into the container as
`/root/models/models.ini` and passed to llama.cpp as `--models-preset`.
The active Qwen3.6 presets use 262144 context per request, `parallel = 1`, full
`f16` KV cache, device KV offload, unified KV, context checkpoints with
`cache-ram = 32768`, `image-min-tokens = 1024`, `reasoning = on`, and
provider-qualified model names. `bin/run.sh` supplies backend-specific
`batch-size` and `ubatch-size` values on the preset server command line so ROCm
can use larger prefill microbatches without making the shared preset unsafe for
Vulkan. `parallel > 1` splits `ctx-size` across server slots unless `ctx-size`
is raised accordingly. Clients select models by preset name:

```bash
curl http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "unsloth/Qwen3.6-27B-MTP-GGUF:UD-Q4_K_XL",
    "messages": [{"role": "user", "content": "Write a short Rust CLI plan."}]
  }'
```

Every Qwen3.6 preset also has a `:non-reasoning` variant that uses
`reasoning = off` and the non-thinking sampling defaults from the Unsloth
Qwen3.6 guidance. For example:

```json
"model": "unsloth/Qwen3.6-27B-MTP-GGUF:UD-Q4_K_XL:non-reasoning"
```

Use `LLAMA_MODELS_PRESET` to point at another preset under `MODELS_DIR`:

```bash
LLAMA_MODELS_PRESET=/var/mnt/xdata/models/models-sample-2.ini \
  bin/run.sh rocm server
```

`models/models.ini` uses llama.cpp's documented `[*]` global section to keep
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
the shared fallback values in `models/models.ini`, letting ROCm use larger
microbatches while keeping the preset file usable for raw/manual Vulkan runs.

One alternative is worth considering if the `default` artifact becomes too
noisy:

- Keep a DRY `models.template.ini` and have the helper generate an expanded
  temporary INI before launch. This preserves per-model override behavior and
  avoids `default`, but adds custom preprocessing before every preset server
  start.

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

Use `bin/build.sh` to build next-workflow images from `containers/Containerfile`.
See [build.md](build.md) for build targets and smoke tests.

Start `llama-server` with draft MTP enabled:

```bash
bin/run.sh rocm mtp-server \
  /var/mnt/xdata/models/qwen-mtp/model.gguf \
  3
```

The `3` means `--spec-draft-n-max 3`. Use `2` for MTP-2.

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

The active `models/models.ini` Qwen3.6 presets override the direct-run context
baseline with the model maximum, `ctx-size = 262144`, and enable YaRN with
`rope-scaling = yarn`, `rope-scale = 8`, and `yarn-orig-ctx = 32768`. This
matches Qwen-family guidance for extending beyond native 32k context; for short
prompt latency or quality comparisons, test a separate preset without static
YaRN. `bin/run.sh` overrides the preset file's fallback `batch-size` and
`ubatch-size` with the backend defaults above.

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
  -p 8080:8080 \
  localhost/amd-strix-halo-toolboxes:vulkan \
  llama-server --models-preset /root/models/models.ini --models-max 1 \
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
  -p 8080:8080 \
  localhost/amd-strix-halo-toolboxes:rocm \
  llama-server --models-preset /root/models/models.ini --models-max 1 \
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
  localhost/amd-strix-halo-toolboxes:vulkan \
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

The helper always adds `-fa 1` and `--no-mmap` for direct-model `server`, `mtp-server`, `load-test`, and `cli` because those are required for reliable Strix Halo runs. Preset `server` takes those settings from `models/models.ini`. For `bench`, it uses `-fa 1`, `-mmp 0`, `-p 2048`, `-n 32`, `-d 131072`, and the backend-specific `-ub` value.

The preset passed to `server` and the model path passed to `server`, `mtp-server`, `load-test`, `cli`, or `bench` must be under `MODELS_DIR`, because only that directory is mounted into the container.
