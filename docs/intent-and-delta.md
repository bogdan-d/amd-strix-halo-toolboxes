# Next-Workflow Intent and Fork Delta

This document summarizes the local direction added after the upstream fork.
Use it as the high-level map before changing `containers/`, `bin/`, or
`docs-next/`.

## Intent

The local next workflow is moving this repository from a legacy
Toolbx/Distrobox-first project toward raw Podman/Docker-compatible images for
AMD Strix Halo llama.cpp work.

The goal is to make the common path direct and reproducible:

- build runtime images from one `containers/Containerfile`;
- run those images with plain Podman;
- keep Strix Halo defaults encoded in host-side helpers;
- preserve the legacy upstream files so rebasing remains practical.

Until this direction is ready to replace or extend upstream behavior, keep the
next work isolated in `README-next.md`, `containers/`, `bin/`, and `docs-next/`.

## Added Since Upstream Fork

The local branch adds the next-workflow surface:

- `README-next.md` as the entry point for the experimental raw-container flow;
- `AGENTS.override.md` as active local guidance for agents;
- `docs-next/` for next-workflow documentation;
- `containers/Containerfile` as the shared Fedora-based build for ROCm and
  Vulkan images;
- `bin/build.sh` for Buildah/Podman image builds;
- `bin/run.sh` for running llama.cpp containers with Strix Halo
  defaults;
- `bin/clear.sh` for clearing local next-workflow images, containers, builder
  cache, and build logs;
- `bin/env-defaults.sh` for loading `.env` defaults without overriding existing
  environment variables;
- `.gitignore` entries for `.env`, `.build-logs/`, `/models`, and local scratch
  output.

## Container Targets

The next workflow currently supports six build types across two Containerfiles:

| Build type | Default tag | Purpose |
| :--- | :--- | :--- |
| `rocm` | `localhost/strix-llama:rocm` | Stable ROCm, defaulting to ROCm 7.2.4. |
| `rocm-next` | `localhost/strix-llama:rocm-next` | ROCm nightly tarball builds from TheRock for `gfx1151`. |
| `vulkan` | `localhost/strix-llama:vulkan` | Fedora Mesa RADV Vulkan runtime. |
| `vulkan-fpx` | `localhost/strix-llama:vulkan-fpx` | Explicit experimental Vulkan build of the custom ROCmFPX llama.cpp fork. |
| `rocm-fpx` | `localhost/strix-llama:rocm-fpx` | Explicit experimental stable ROCm build of the custom ROCmFPX llama.cpp fork. |
| `rocm-next-fpx` | `localhost/strix-llama:rocm-next-fpx` | Explicit experimental ROCm nightly build of the custom ROCmFPX llama.cpp fork. |

`containers/Containerfile` is the stock llama.cpp build path for `rocm`,
`rocm-next`, and `vulkan`. `containers/Containerfile.rocmfpx` is the isolated ROCmFPX fork build path for
`vulkan-fpx`, `rocm-fpx`, and `rocm-next-fpx`, with its own source cache.

The stock targets follow the same llama.cpp source line by default. The old ROCm-only
`95405ac65` pin worked around Strix Halo ROCm model-load crashes while the
runtime environment was still being narrowed down. The recent latest-llama.cpp
crash reproduced when ROCm/HIP paths were exported process-wide in the runtime
environment; current images avoid those exports and expose ROCm libraries
through `ldconfig` instead. Use `LLAMA_REF` only for testing, bisects, or
deliberately preserved test builds across stock backends. The default
repository is `ggml-org/llama.cpp`, matching the current canonical upstream
after the old `ggerganov` path began redirecting. The `*-fpx` targets use `charlie12345/ROCmFPX` branch `main` pinned at
`014cd28b97d539a0365979d88e9846fad5aa822b`. Those images also build the
fork's local validation tools (`llama-completion`, `llama-perplexity`,
`test-backend-ops`, `test-quantize-fns`, and `test-quantize-perf`) because the
ROCmFPX repo's smoke and regression scripts use them. The older
`charlie12345/rocmfp4-llama` image path has been removed; ROCmFPX remains
compatible with the existing ROCmFP4 model naming/config patterns.

## Build Workflow

`bin/build.sh` is the primary build entry point. It defaults to Buildah and can
also use Podman through `BUILDER=podman`.

Important behavior added locally:

- target aliases such as `rocm`, `rocm=7.2.4`, `rocm-next`,
  `rocm7-nightlies`, `vulkan`, `vulkan-radv`, `vulkan-fpx`, `rocm-fpx`, and
  `rocm-next-fpx`;
- automatic Containerfile selection: stock targets use `containers/Containerfile`
  and ROCmFPX targets use `containers/Containerfile.rocmfpx`;
- `LLAMA_REF` to optionally pin llama.cpp across stock backends for tests,
  bisects, or preserved builds;
- `ROCMFPX_LLAMA_REPO`, `ROCMFPX_LLAMA_BRANCH`, and `ROCMFPX_LLAMA_REF` for
  the explicit FPX fork target;
- `ROCMFPX_DECODE_TUNE` for opt-in Strix ROCmFPX decode launch tuning while
  keeping the default profile at the fork's conservative `stable` setting;
- `CPU_TARGET=generic|strix-halo|native`, with `generic` as the reproducible
  default;
- `ROCWMMA_FATTN=1` or `bin/build.sh --with-rocwmma` to opt ROCm builds into
  llama.cpp's rocWMMA flash-attention kernels;
- non-generic CPU targets write variant tags only, so they do not overwrite the
  default image tags;
- `BUILD_CACHE_REPO` support for remote Buildah cache repositories;
- `BUILD_LOG_MODE=progress` as the default, writing full logs under
  `.build-logs/` while printing phase markers and important warnings/errors.

See [build.md](build.md) for commands and smoke tests.
See [rocmfpx-fork.md](rocmfpx-fork.md) for notes on the ROCmFPX fork,
quantization profile meanings, and Strix profile tradeoffs.

## Runtime Workflow

`bin/run.sh` is the primary runtime helper. It maps local backend names to image
tags, using same `CPU_TARGET` and `ROCM_VERSION` defaults as `bin/build.sh` so
runtime selection matches build tags. It mounts the model directory, exposes
the server port, generates a temporary `llama-server --models-preset` from
`models-template.ini` and discovered GGUF files by default, and keeps direct
model paths available for one-off runs.

Important defaults:

- `models-template.ini` as the tracked source for generated llama.cpp
  `--models-preset` files;
- provider-qualified model IDs generated from `author/repo:quant` paths;
- Qwen3.6 preset defaults with `ctx-size = 262144` as the total server context
  pool, `parallel = 4`, `q8_0` KV cache, device KV offload, unified KV,
  context checkpoints with `cache-ram = 32768`,
  `image-min-tokens = 1024`, and coding-agent sampling defaults in the active
  preset;
- `:non-reasoning` preset variants for each discovered Qwen/Qwen-derived model, using
  `reasoning = off` and non-thinking sampling defaults;
- automatic same-directory `mmproj*.gguf` pairing and MTP speculation settings
  for paths or filenames containing `MTP` or `mtp`;
- FPX-only generated presets for the `*-fpx` backends, with normal generated
  presets excluding ROCmFPX-compatible GGUFs so stock images do not route to
  incompatible models;
- generated presets keep shared defaults in `[*]`; this can expose a broken
  `default` router model, so clients should not request `default`;
- `-fa 1` for direct server, MTP server, CLI, and bench;
- `--no-mmap` for direct server, MTP server, and CLI;
- full GPU offload by default for server/CLI;
- `262144` total context for active Qwen3.6 presets, with RoPE/YaRN overrides
  documented but disabled in `models-template.ini` for explicit long-context
  experiments;
- `131072` context and `2048` batch as the direct-run baseline;
- backend-specific microbatch defaults: `512` for Vulkan/FPX and `2048` for
  stock ROCm;
- `/dev/dri` for Vulkan/Vulkan FPX and `/dev/dri` plus `/dev/kfd` for
  ROCm/ROCmFPX;
- Hugging Face cache mounting through `HF_CACHE_DIR` and `HF_HOME`;
- automatic `.env` loading for runtime environment variables.
- `load-test` for bounded model-load smoke tests that start `llama-server`,
  wait until the model is loaded, and stop the container.

See [podman.md](podman.md) for the complete runtime flow and raw `podman run`
examples.

## Legacy Boundary

Treat these paths as upstream-aligned unless intentionally preparing an
upstream-facing patch:

- `README.md`
- `toolboxes/`
- `refresh-toolboxes.sh`
- `.github/workflows/`
- existing `docs/`

Local next-workflow changes should normally stay in:

- `README-next.md`
- `containers/`
- `bin/`
- `docs-next/`

When a legacy asset is reused from the next Containerfile, document that coupling
instead of moving or rewriting the legacy file casually.
