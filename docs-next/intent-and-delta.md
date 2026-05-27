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
- `bin/podman-llama.sh` for running llama.cpp containers with Strix Halo
  defaults;
- `bin/clear.sh` for clearing local next-workflow images, containers, builder
  cache, and build logs;
- `bin/env-defaults.sh` for loading `.env` defaults without overriding existing
  environment variables;
- `.gitignore` entries for `.env`, `.build-logs/`, `/models`, and local scratch
  output.

## Container Targets

The shared Containerfile currently supports three build types:

| Build type | Default tag | Purpose |
| :--- | :--- | :--- |
| `rocm` | `localhost/amd-strix-halo-toolboxes:rocm` | Stable ROCm, defaulting to ROCm 7.2.3. |
| `rocm-next` | `localhost/amd-strix-halo-toolboxes:rocm-next` | ROCm nightly tarball builds from TheRock for `gfx1151`. |
| `vulkan` | `localhost/amd-strix-halo-toolboxes:vulkan` | Fedora Mesa RADV Vulkan runtime. |

The stable ROCm target pins llama.cpp to `95405ac65` by default because newer
llama.cpp master has crashed during HIP stream creation on Strix Halo with ROCm
7.2.3. The default repository is `ggml-org/llama.cpp`, matching the current
canonical upstream after the old `ggerganov` path began redirecting.

## Build Workflow

`bin/build.sh` is the primary build entry point. It defaults to Buildah and can
also use Podman through `BUILDER=podman`.

Important behavior added locally:

- target aliases such as `rocm`, `rocm=7.2.3`, `rocm-next`, `rocm7-nightlies`,
  `vulkan`, and `vulkan-radv`;
- `LLAMA_ROCM_REF` to keep the stable ROCm build pinned while still allowing
  experiments;
- `CPU_TARGET=generic|strix-halo|native`, with `generic` as the reproducible
  default;
- non-generic CPU targets write variant tags only, so they do not overwrite the
  default image tags;
- `BUILD_CACHE_REPO` support for remote Buildah cache repositories;
- `BUILD_LOG_MODE=progress` as the default, writing full logs under
  `.build-logs/` while printing phase markers and important warnings/errors.

See [build.md](build.md) for commands and smoke tests.

## Runtime Workflow

`bin/podman-llama.sh` is the primary runtime helper. It maps local backend names
to image tags, mounts the model directory, exposes server/RPC ports, and applies
Strix Halo llama.cpp defaults.

Important defaults:

- `-fa 1` for server, MTP server, CLI, and bench;
- `--no-mmap` for server, MTP server, and CLI;
- full GPU offload by default for server/CLI;
- `32768` context and `2048` batch as the baseline;
- backend-specific microbatch defaults: `512` for Vulkan and `2048` for ROCm;
- `/dev/dri` for Vulkan and `/dev/dri` plus `/dev/kfd` for ROCm;
- Hugging Face cache mounting through `HF_CACHE_DIR` and `HF_HOME`;
- automatic `.env` loading for runtime environment variables.

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
