# Building Next-Workflow Images

Build from the repository root. The next workflow uses
`containers/Containerfile` for stock ROCm/Vulkan images and
`containers/Containerfile.rocmfp4` for the custom ROCmFP4 llama.cpp fork
targets.

## Quick Start

Build all next-workflow images:

```bash
bin/build.sh
```

Build one image:

```bash
bin/build.sh rocm
bin/build.sh rocm-next
bin/build.sh vulkan
bin/build.sh vulkan-rfp4
bin/build.sh rocm-rfp4
bin/build.sh rocm-next-rfp4
```

The default tags are:

| Target | Image |
| :--- | :--- |
| `rocm` | `localhost/amd-strix-halo-toolboxes:rocm` |
| `rocm-next` | `localhost/amd-strix-halo-toolboxes:rocm-next` |
| `vulkan` | `localhost/amd-strix-halo-toolboxes:vulkan` |
| `vulkan-rfp4` | `localhost/amd-strix-halo-toolboxes:vulkan-rfp4` |
| `rocm-rfp4` | `localhost/amd-strix-halo-toolboxes:rocm-rfp4` |
| `rocm-next-rfp4` | `localhost/amd-strix-halo-toolboxes:rocm-next-rfp4` |

By default, `rocm` is also tagged as
`localhost/amd-strix-halo-toolboxes:rocm-7.2.4`, and `rocm-next` is also tagged
as `localhost/amd-strix-halo-toolboxes:rocm7-nightlies`.
The `*-rfp4` targets are experimental and explicit-only: they are not part of
`bin/build.sh all` because they build a custom llama.cpp fork for ROCmFP4 GGUFs
that stock llama.cpp cannot load. `vulkan-rfp4` uses Fedora Mesa RADV,
`rocm-rfp4` uses stable ROCm packages, and `rocm-next-rfp4` uses the ROCm
nightly/TheRock runtime path.

## Build Script

`bin/build.sh` uses Buildah by default:

```bash
bin/build.sh rocm
bin/build.sh rocm=7.2.4
```

By default, the script runs in `BUILD_LOG_MODE=progress`: it writes the full
Buildah/Podman output under `.build-logs/`, while the terminal shows only build
steps, explicit `>>>` phase markers, commit/tag lines, and common error lines.
Use full streaming output when you need raw package-manager or compiler logs:

```bash
BUILD_LOG_MODE=full bin/build.sh rocm
```

Use Podman instead:

```bash
BUILDER=podman bin/build.sh rocm-next
```

Override the image prefix:

```bash
IMAGE_PREFIX=localhost/strix-halo bin/build.sh rocm
```

Override Containerfile paths:

```bash
CONTAINERFILE=containers/Containerfile bin/build.sh rocm
ROCMFP4_CONTAINERFILE=containers/Containerfile.rocmfp4 bin/build.sh rocm-rfp4
```

Rebuild without using cached image layers, while keeping the Buildah storage and
cache mount contents intact:

```bash
bin/build.sh --no-cache rocm
bin/build.sh --no-cache rocm rocm-next vulkan
NO_CACHE=1 bin/build.sh rocm
```

Pass less common build flags with `BUILD_EXTRA_ARGS`:

```bash
BUILD_EXTRA_ARGS="--pull-always" bin/build.sh rocm
```

Enable llama.cpp's rocWMMA flash-attention kernels for ROCm builds:

```bash
bin/build.sh --with-rocwmma rocm rocm-next
ROCWMMA_FATTN=1 bin/build.sh rocm
```

This passes `-DGGML_HIP_ROCWMMA_FATTN=ON` to ROCm CMake builds only. Stable
ROCm builds also install `rocwmma-devel` in the builder stage when enabled.
Vulkan builds ignore this option.

Stock targets leave `LLAMA_REF` empty by default, so they follow
`LLAMA_BRANCH`.
The old ROCm-only `95405ac65` pin was a workaround while debugging Strix Halo
ROCm model-load crashes. The recent latest-llama.cpp crash reproduced when
ROCm/HIP paths were exported process-wide in the runtime environment; current
images avoid those exports and expose ROCm libraries through `ldconfig` instead.
Set `LLAMA_REF` only when testing, bisecting, or preserving a known llama.cpp
build across all backends:

```bash
LLAMA_REF=95405ac65 bin/build.sh rocm
```

The ROCmFP4 targets are isolated from those stock defaults. They build
`https://github.com/charlie12345/rocmfp4-llama.git` branch
`mtp-rocmfp4-strix` pinned to
`a00689039fb26b8ae91e0425b7416bb04f7f15bb`. Override
`ROCMFP4_LLAMA_REPO`, `ROCMFP4_LLAMA_BRANCH`, or `ROCMFP4_LLAMA_REF` only when
testing a new fork build:

```bash
bin/build.sh vulkan-rfp4
bin/build.sh rocm-rfp4
bin/build.sh rocm-next-rfp4
ROCMFP4_LLAMA_REF=mtp-rocmfp4-strix bin/build.sh rocm-rfp4
```

The default CPU target is `generic`, which disables host-native CPU detection so
local and future GitHub runner builds do not silently differ. Use
`CPU_TARGET=strix-halo` to enable explicit Strix Halo AVX512/VNNI/BF16 flags, or
`CPU_TARGET=native` for local experiments:

```bash
CPU_TARGET=strix-halo bin/build.sh rocm
```

Non-generic CPU targets use only variant tags, for example `rocm-strix-halo`,
`rocm-7.2.4-strix-halo`, `rocm-next-strix-halo`, and
`vulkan-rfp4-strix-halo` / `rocm-rfp4-strix-halo` /
`rocm-next-rfp4-strix-halo`. They do not overwrite the default `rocm`,
`rocm-next`, `vulkan`, `vulkan-rfp4`, `rocm-rfp4`, or `rocm-next-rfp4` tags.
Buildah cache repositories and CMake build directories include the CPU target,
so generic and Strix Halo builds do not reuse each other's CMake cache.

Local builds use Buildah's normal layer cache. To push and pull cache through a
real registry in CI, set `BUILD_CACHE_REPO`:

```bash
BUILD_CACHE_REPO=ghcr.io/owner/amd-strix-halo-toolboxes-build-cache bin/build.sh all
```

Disable the extra version/nightly alias tags:

```bash
TAG_VERSION=0 TAG_NIGHTLY_ALIAS=0 bin/build.sh all
```

## Manual Build

The script expands to commands like this:

```bash
buildah bud --pull --format oci --layers \
  --build-arg BUILD_TYPE=rocm \
  --build-arg ROCM_VERSION=7.2.4 \
  --build-arg ROCM_REPO_URL=https://repo.radeon.com/rocm/rhel10/7.2.4/main \
  --build-arg LLAMA_REF= \
  --build-arg CPU_TARGET=generic \
  --build-arg ROCWMMA_FATTN=0 \
  -t localhost/amd-strix-halo-toolboxes:rocm \
  -t localhost/amd-strix-halo-toolboxes:rocm-7.2.4 \
  -f containers/Containerfile .
```

For nightly ROCm:

```bash
buildah bud --pull --format oci --layers \
  --build-arg BUILD_TYPE=rocm-next \
  -t localhost/amd-strix-halo-toolboxes:rocm-next \
  -t localhost/amd-strix-halo-toolboxes:rocm7-nightlies \
  -f containers/Containerfile .
```

For Vulkan RFP4 llama.cpp:

```bash
buildah bud --pull --format oci --layers \
  --build-arg BUILD_TYPE=vulkan-rfp4 \
  --build-arg LLAMA_REPO=https://github.com/charlie12345/rocmfp4-llama.git \
  --build-arg LLAMA_BRANCH=mtp-rocmfp4-strix \
  --build-arg LLAMA_REF=a00689039fb26b8ae91e0425b7416bb04f7f15bb \
  -t localhost/amd-strix-halo-toolboxes:vulkan-rfp4 \
  -f containers/Containerfile.rocmfp4 .
```

For stable ROCm RFP4 llama.cpp:

```bash
buildah bud --pull --format oci --layers \
  --build-arg BUILD_TYPE=rocm-rfp4 \
  --build-arg LLAMA_REPO=https://github.com/charlie12345/rocmfp4-llama.git \
  --build-arg LLAMA_BRANCH=mtp-rocmfp4-strix \
  --build-arg LLAMA_REF=a00689039fb26b8ae91e0425b7416bb04f7f15bb \
  -t localhost/amd-strix-halo-toolboxes:rocm-rfp4 \
  -f containers/Containerfile.rocmfp4 .
```

For ROCm nightly RFP4 llama.cpp:

```bash
buildah bud --pull --format oci --layers \
  --build-arg BUILD_TYPE=rocm-next-rfp4 \
  --build-arg LLAMA_REPO=https://github.com/charlie12345/rocmfp4-llama.git \
  --build-arg LLAMA_BRANCH=mtp-rocmfp4-strix \
  --build-arg LLAMA_REF=a00689039fb26b8ae91e0425b7416bb04f7f15bb \
  -t localhost/amd-strix-halo-toolboxes:rocm-next-rfp4 \
  -f containers/Containerfile.rocmfp4 .
```

For Vulkan:

```bash
buildah bud --pull --format oci --layers \
  --build-arg BUILD_TYPE=vulkan \
  -t localhost/amd-strix-halo-toolboxes:vulkan \
  -f containers/Containerfile .
```

The Containerfiles use Buildah cache mounts for DNF packages, ROCm nightly
tarballs, and llama.cpp checkouts. Stock and ROCmFP4 builds use separate
llama.cpp source caches so the fork branch does not churn the stock worktree.
They build only the runtime targets used by the next workflow: `llama-server`,
`llama-cli`, `llama-bench`, and `llama-gguf-split`. They also copy the shared
patch and helper assets from `toolboxes/`. Each build resets the cached
llama.cpp worktree before switching refs and applying local patches, so dirty
source files left by one backend do not break the next backend build.

## Smoke Tests

Check the built binaries:

```bash
podman run --rm localhost/amd-strix-halo-toolboxes:rocm llama-server --version
podman run --rm localhost/amd-strix-halo-toolboxes:rocm-next llama-server --version
podman run --rm localhost/amd-strix-halo-toolboxes:vulkan llama-server --version
podman run --rm localhost/amd-strix-halo-toolboxes:vulkan-rfp4 llama-server --version
podman run --rm localhost/amd-strix-halo-toolboxes:rocm-rfp4 llama-server --version
podman run --rm localhost/amd-strix-halo-toolboxes:rocm-next-rfp4 llama-server --version
```

Check GPU visibility:

```bash
podman run --rm \
  --security-opt seccomp=unconfined \
  --security-opt label=disable \
  --group-add keep-groups \
  --device /dev/dri \
  --device /dev/kfd \
  localhost/amd-strix-halo-toolboxes:rocm \
  llama-cli --list-devices

podman run --rm \
  --security-opt seccomp=unconfined \
  --security-opt label=disable \
  --group-add keep-groups \
  --device /dev/dri \
  --device /dev/kfd \
  localhost/amd-strix-halo-toolboxes:rocm-next \
  llama-cli --list-devices

podman run --rm \
  --security-opt seccomp=unconfined \
  --security-opt label=disable \
  --group-add keep-groups \
  --device /dev/dri \
  localhost/amd-strix-halo-toolboxes:vulkan-rfp4 \
  llama-cli --list-devices

podman run --rm \
  --security-opt seccomp=unconfined \
  --security-opt label=disable \
  --group-add keep-groups \
  --device /dev/dri \
  --device /dev/kfd \
  --env HSA_OVERRIDE_GFX_VERSION=11.5.1 \
  --env GGML_HIP_ENABLE_UNIFIED_MEMORY=1 \
  localhost/amd-strix-halo-toolboxes:rocm-rfp4 \
  llama-cli --list-devices

podman run --rm \
  --security-opt seccomp=unconfined \
  --security-opt label=disable \
  --group-add keep-groups \
  --device /dev/dri \
  --device /dev/kfd \
  --env HSA_OVERRIDE_GFX_VERSION=11.5.1 \
  --env GGML_HIP_ENABLE_UNIFIED_MEMORY=1 \
  localhost/amd-strix-halo-toolboxes:rocm-next-rfp4 \
  llama-cli --list-devices

podman run --rm \
  --security-opt seccomp=unconfined \
  --security-opt label=disable \
  --group-add keep-groups \
  --device /dev/dri \
  localhost/amd-strix-halo-toolboxes:vulkan \
  llama-cli --list-devices
```

Check model-load without leaving a server running:

```bash
bin/run.sh rocm load-test /var/mnt/xdata/models/qwen/model.gguf
```

`load-test` starts `llama-server` detached, waits for the model-loaded log line,
prints the last server logs, and stops the container. Use
`LLAMA_LOAD_TEST_TIMEOUT=180` for very large models.
