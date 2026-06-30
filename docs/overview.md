# Overview

This repository builds and runs [llama.cpp] optimally on **AMD Ryzen AI Max
"Strix Halo"** (gfx1151) integrated GPUs, using plain Podman/Docker-compatible
containers that expose the APU's unified memory (up to ~124 GiB usable as GPU
memory) across ROCm and Vulkan backends.

The common path is direct and reproducible:

- build runtime images from `containers/Containerfile` (stock) and
  `containers/Containerfile.rocmfpx` (ROCmFPX fork);
- run those images with plain Podman through `bin/run.sh`;
- keep Strix Halo defaults encoded in the host-side helpers so raw `podman run`
  callers and the helper agree.

## Repository layout

- `containers/` — `Containerfile` (stock backends) and `Containerfile.rocmfpx`
  (ROCmFPX fork backends), plus `rocmfpx-warning.patch`.
- `bin/` — host-side helpers:
  - `build.sh` — Buildah/Podman image builds;
  - `run.sh` — Podman runtime wrapper with Strix Halo defaults;
  - `clear.sh` — clear local images, containers, builder cache, and build logs;
  - `env-defaults.sh` — load `.env` without overriding existing env vars;
  - `generate-models-preset.sh` and the coding-tool config generators.
- `patches/` — build assets copied into images (`llama-grammar.patch`).
- `scripts/` — host utilities copied into images
  (`gguf-vram-estimator.py`) plus benchmark helpers.
- `docs/` — user and contributor documentation.
- `benchmark/` — throughput/latency/MTP benchmark runner scripts.
- `models-template.ini` — tracked source for generated `--models-preset` files.

## Container targets

Six build types are supported across two Containerfiles:

| Build type      | Default tag                          | Purpose                                                            |
|:----------------|:-------------------------------------|:-------------------------------------------------------------------|
| `rocm`          | `localhost/strix-llama:rocm`         | Stable ROCm, defaulting to ROCm 7.2.4.                             |
| `rocm-next`     | `localhost/strix-llama:rocm-next`    | ROCm nightly tarball builds from TheRock for `gfx1151`.            |
| `vulkan`        | `localhost/strix-llama:vulkan`       | Fedora Mesa RADV Vulkan runtime.                                   |
| `vulkan-fpx`    | `localhost/strix-llama:vulkan-fpx`   | Vulkan build of the custom ROCmFPX llama.cpp fork.                 |
| `rocm-fpx`      | `localhost/strix-llama:rocm-fpx`     | Stable ROCm build of the custom ROCmFPX llama.cpp fork.            |
| `rocm-next-fpx` | `localhost/strix-llama:rocm-next-fpx`| ROCm nightly build of the custom ROCmFPX llama.cpp fork.           |

`containers/Containerfile` is the stock build path for `rocm`, `rocm-next`, and
`vulkan`. `containers/Containerfile.rocmfpx` is the isolated ROCmFPX fork build
path for `vulkan-fpx`, `rocm-fpx`, and `rocm-next-fpx`, with its own source
cache.

Both stock and FPX targets pin their llama.cpp checkout to a commit id read from
the gitignored `.env` (`STOCK_LLAMA_BRANCH` / `FPX_LLAMA_BRANCH`, each tracking
its branch HEAD); clear a pin to float on the branch tip, or override per build
with `LLAMA_REF` / `ROCMFPX_LLAMA_REF`. Stock targets use canonical
`ggml-org/llama.cpp` `master`. The `*-fpx` targets use `charlie12345/ROCmFPX`
branch `main` and also build the fork's local validation tools
(`llama-completion`, `llama-perplexity`, `test-backend-ops`,
`test-quantize-fns`, `test-quantize-perf`) because the ROCmFPX smoke and
regression scripts use them.

## Build workflow

`bin/build.sh` is the primary build entry point. It defaults to **buildah** and
can also use Podman through `BUILDER=podman`. Notable behavior:

- target aliases: `rocm`, `rocm=7.2.4`, `rocm-next`, `rocm7-nightlies`,
  `vulkan`, `vulkan-radv`, `vulkan-fpx`, `rocm-fpx`, `rocm-next-fpx`;
- automatic Containerfile selection — stock targets use `containers/Containerfile`,
  ROCmFPX targets use `containers/Containerfile.rocmfpx`;
- `STOCK_LLAMA_BRANCH` / `FPX_LLAMA_BRANCH` (in `.env`) to pin the llama.cpp
  checkout per branch; `LLAMA_REF` / `ROCMFPX_LLAMA_REF` override it per build;
- `ROCMFPX_LLAMA_REPO` / `ROCMFPX_LLAMA_BRANCH` for the FPX fork source;
- `ROCMFPX_DECODE_TUNE` for opt-in Strix ROCmFPX decode launch tuning (default
  `stable`);
- `CPU_TARGET=generic|strix-halo|native` (`generic` is the reproducible default);
  non-generic targets write variant tags only and never overwrite the default tags;
- `ROCWMMA_FATTN=1` or `bin/build.sh --with-rocwmma` to opt ROCm builds into
  llama.cpp's rocWMMA flash-attention kernels;
- `BUILD_CACHE_REPO` for remote Buildah cache repositories;
- `BUILD_LOG_MODE=progress` (default) — full logs under `.build-logs/` with phase
  markers and warnings/errors printed live.

See [build.md](build.md) for commands and smoke tests, and
[rocmfpx-fork.md](rocmfpx-fork.md) for the ROCmFPX fork, quantization profile
meanings, and Strix profile tradeoffs.

## Runtime workflow

`bin/run.sh` is the primary runtime helper. It maps local backend names to image
tags using the same `CPU_TARGET` and `ROCM_VERSION` defaults as `bin/build.sh`,
so runtime selection matches build tags. It mounts the model directory, exposes
the server port, generates a temporary `llama-server --models-preset` from
`models-template.ini` and discovered GGUF files by default, and keeps direct
model paths available for one-off runs.

Defaults encoded by the helper:

- `models-template.ini` as the tracked source for generated `--models-preset`
  files; provider-qualified model IDs derived from `author/model-file-stem`;
- Qwen3.6 preset defaults: `ctx-size = 262144` total server context pool,
  `parallel = 4`, `q8_0` KV cache, device KV offload, unified KV, context
  checkpoints (`cache-ram = 32768`), `image-min-tokens = 1024`, coding-agent
  sampling defaults;
- `~non-reasoning` preset variants for each discovered Qwen/Qwen-derived model
  (`reasoning = off`, non-thinking sampling);
- automatic same-directory `mmproj*.gguf` pairing and MTP speculation settings
  for paths/filenames containing `MTP` or `mtp`;
- FPX-only generated presets for the `*-fpx` backends; normal generated presets
  exclude ROCmFPX-compatible GGUFs so stock images never route to incompatible
  models;
- generated presets keep shared defaults in `[*]`, which can expose a broken
  `default` router model — clients should not request `default`;
- `-fa 1` for direct server, MTP server, CLI, and bench; `--no-mmap` for direct
  server, MTP server, and CLI; full GPU offload by default for server/CLI;
- `262144` total context for active Qwen3.6 presets (RoPE/YaRN overrides
  documented but disabled in `models-template.ini` for explicit long-context
  experiments); `131072` context and `2048` batch as the direct-run baseline;
- backend-specific microbatch defaults: `512` for Vulkan/FPX, `2048` for stock
  ROCm;
- `/dev/dri` for Vulkan/Vulkan FPX, and `/dev/dri` plus `/dev/kfd` for
  ROCm/ROCmFPX;
- Hugging Face cache mounting through `HF_CACHE_DIR` and `HF_HOME`;
- automatic `.env` loading for runtime environment variables;
- `load-test` for bounded model-load smoke tests that start `llama-server`, wait
  until the model is loaded, then stop the container.

See [podman.md](podman.md) for the complete runtime flow and raw `podman run`
examples, and [llama-cpp-args.md](llama-cpp-args.md) for the full argument map.

[llama.cpp]: https://github.com/ggml-org/llama.cpp
