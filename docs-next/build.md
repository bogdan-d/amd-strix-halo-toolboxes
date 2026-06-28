# Building Next-Workflow Images

Build from the repository root. The next workflow uses
`containers/Containerfile` for stock ROCm/Vulkan images and
`containers/Containerfile.rocmfp4` for the custom ROCmFP4 llama.cpp fork
targets. `containers/Containerfile.rocmfpx` builds the newer ROCmFPX fork for
Vulkan, stable ROCm, and ROCm nightlies.

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
bin/build.sh vulkan-fp4
bin/build.sh rocm-fp4
bin/build.sh rocm-next-fp4
bin/build.sh vulkan-fpx
bin/build.sh rocm-fpx
bin/build.sh rocm-next-fpx
```

The default tags are:

| Target | Image |
| :--- | :--- |
| `rocm` | `localhost/strix-llama:rocm` |
| `rocm-next` | `localhost/strix-llama:rocm-next` |
| `vulkan` | `localhost/strix-llama:vulkan` |
| `vulkan-fp4` | `localhost/strix-llama:vulkan-fp4` |
| `rocm-fp4` | `localhost/strix-llama:rocm-fp4` |
| `rocm-next-fp4` | `localhost/strix-llama:rocm-next-fp4` |
| `vulkan-fpx` | `localhost/strix-llama:vulkan-fpx` |
| `rocm-fpx` | `localhost/strix-llama:rocm-fpx` |
| `rocm-next-fpx` | `localhost/strix-llama:rocm-next-fpx` |

By default, `rocm` is also tagged as
`localhost/strix-llama:rocm-7.2.4`, and `rocm-next` is also tagged
as `localhost/strix-llama:rocm7-nightlies`.
The `*-fp4` targets are experimental and explicit-only: they are not part of
`bin/build.sh all` because they build a custom llama.cpp fork for ROCmFP4 GGUFs
that stock llama.cpp cannot load. `vulkan-fp4` uses Fedora Mesa RADV,
`rocm-fp4` uses stable ROCm packages, and `rocm-next-fp4` uses the ROCm
nightly/TheRock runtime path.
The `*-fpx` targets are also explicit-only and build the newer ROCmFPX fork
against the same Vulkan/stable ROCm/ROCm nightly backend matrix.

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
ROCMFP4_CONTAINERFILE=containers/Containerfile.rocmfp4 bin/build.sh rocm-fp4
ROCMFPX_CONTAINERFILE=containers/Containerfile.rocmfpx bin/build.sh rocm-fpx
```

`rocm-next` and `rocm-next-fp4` pin their TheRock runtime tarball by default
because the newest nightly can regress GPU discovery independently of llama.cpp.
Override the pin, or set it empty to resolve the newest available tarball:

```bash
ROCM_NIGHTLY_TARBALL=therock-dist-linux-gfx1151-7.14.0a20260612.tar.gz \
  bin/build.sh rocm-next-fp4

ROCM_NIGHTLY_TARBALL= bin/build.sh rocm-next-fp4
```

`ROCMFP4_ROCM_NIGHTLY_TARBALL` remains accepted as a deprecated alias for the
FP4 workflow.

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
`4795079b04f5e0ada6e5d2e85b12bac1e27e7873`. Override
`ROCMFP4_LLAMA_REPO`, `ROCMFP4_LLAMA_BRANCH`, or `ROCMFP4_LLAMA_REF` only when
testing a new fork build:

```bash
bin/build.sh vulkan-fp4
bin/build.sh rocm-fp4
bin/build.sh rocm-next-fp4
ROCMFP4_LLAMA_REF=mtp-rocmfp4-strix bin/build.sh rocm-fp4
```

The ROCmFPX targets are isolated from stock and FP4 defaults. They build
`https://github.com/charlie12345/ROCmFPX.git` branch `main` pinned to
`014cd28b97d539a0365979d88e9846fad5aa822b`. Override
`ROCMFPX_LLAMA_REPO`, `ROCMFPX_LLAMA_BRANCH`, or `ROCMFPX_LLAMA_REF` only when
testing a newer ROCmFPX revision:

```bash
bin/build.sh vulkan-fpx
bin/build.sh rocm-fpx
bin/build.sh rocm-next-fpx
ROCMFPX_LLAMA_REF=main bin/build.sh rocm-fpx
```

The ROCmFP4 HIP builds follow the fork's Strix-oriented CMake defaults:
`GGML_HIP=ON`, `GGML_HIP_FORCE_MMQ=ON`, `GGML_VULKAN=ON`, `GGML_CUDA=OFF`,
and both `CMAKE_HIP_ARCHITECTURES` and `GPU_TARGETS` set to this repo's
`GFX_TARGET`. The ROCmFP4 ROCm images therefore include Fedora Vulkan RADV
packages as the fork-recommended fallback backend. Unlike the stock ROCm
Containerfile, `containers/Containerfile.rocmfp4` does not add the local
`-mllvm --amdgpu-unroll-threshold-local=600` HIP flag. It only passes
`-Wno-nan-infinity-disabled` through `CMAKE_HIP_FLAGS` to suppress repeated
Clang diagnostics from the fork's intentional HIP fast-math setting.
The ROCmFP4 Vulkan build follows the fork's Vulkan-only defaults:
`GGML_VULKAN=ON`, `GGML_HIP=OFF`, and `GGML_CUDA=OFF`.

The default CPU target is `generic`, which disables host-native CPU detection so
local and future GitHub runner builds do not silently differ. Use
`CPU_TARGET=strix-halo` to enable explicit Strix Halo AVX512/VNNI/BF16 flags, or
`CPU_TARGET=native` for local experiments:

```bash
CPU_TARGET=strix-halo bin/build.sh rocm
```

Non-generic CPU targets use only variant tags, for example `rocm-strix-halo`,
`rocm-7.2.4-strix-halo`, `rocm-next-strix-halo`, and
`vulkan-fp4-strix-halo` / `rocm-fp4-strix-halo` /
`rocm-next-fp4-strix-halo`, `vulkan-fpx-strix-halo`,
`rocm-fpx-strix-halo`, and `rocm-next-fpx-strix-halo`. They do not overwrite
the default `rocm`, `rocm-next`, `vulkan`, `vulkan-fp4`, `rocm-fp4`,
`rocm-next-fp4`, `vulkan-fpx`, `rocm-fpx`, or `rocm-next-fpx` tags.
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
  -t localhost/strix-llama:rocm \
  -t localhost/strix-llama:rocm-7.2.4 \
  -f containers/Containerfile .
```

For nightly ROCm:

```bash
buildah bud --pull --format oci --layers \
  --build-arg BUILD_TYPE=rocm-next \
  --build-arg ROCM_NIGHTLY_TARBALL=therock-dist-linux-gfx1151-7.13.0a20260515.tar.gz \
  -t localhost/strix-llama:rocm-next \
  -t localhost/strix-llama:rocm7-nightlies \
  -f containers/Containerfile .
```

For Vulkan FP4 llama.cpp:

```bash
buildah bud --pull --format oci --layers \
  --build-arg BUILD_TYPE=vulkan-fp4 \
  --build-arg LLAMA_REPO=https://github.com/charlie12345/rocmfp4-llama.git \
  --build-arg LLAMA_BRANCH=mtp-rocmfp4-strix \
  --build-arg LLAMA_REF=4795079b04f5e0ada6e5d2e85b12bac1e27e7873 \
  -t localhost/strix-llama:vulkan-fp4 \
  -f containers/Containerfile.rocmfp4 .
```

For stable ROCm FP4 llama.cpp:

```bash
buildah bud --pull --format oci --layers \
  --build-arg BUILD_TYPE=rocm-fp4 \
  --build-arg LLAMA_REPO=https://github.com/charlie12345/rocmfp4-llama.git \
  --build-arg LLAMA_BRANCH=mtp-rocmfp4-strix \
  --build-arg LLAMA_REF=4795079b04f5e0ada6e5d2e85b12bac1e27e7873 \
  -t localhost/strix-llama:rocm-fp4 \
  -f containers/Containerfile.rocmfp4 .
```

For ROCm nightly FP4 llama.cpp:

```bash
buildah bud --pull --format oci --layers \
  --build-arg BUILD_TYPE=rocm-next-fp4 \
  --build-arg LLAMA_REPO=https://github.com/charlie12345/rocmfp4-llama.git \
  --build-arg LLAMA_BRANCH=mtp-rocmfp4-strix \
  --build-arg LLAMA_REF=4795079b04f5e0ada6e5d2e85b12bac1e27e7873 \
  --build-arg ROCM_NIGHTLY_TARBALL=therock-dist-linux-gfx1151-7.13.0a20260515.tar.gz \
  -t localhost/strix-llama:rocm-next-fp4 \
  -f containers/Containerfile.rocmfp4 .
```

For Vulkan FPX llama.cpp:

```bash
buildah bud --pull --format oci --layers \
  --build-arg BUILD_TYPE=vulkan-fpx \
  --build-arg LLAMA_REPO=https://github.com/charlie12345/ROCmFPX.git \
  --build-arg LLAMA_BRANCH=main \
  --build-arg LLAMA_REF=014cd28b97d539a0365979d88e9846fad5aa822b \
  -t localhost/strix-llama:vulkan-fpx \
  -f containers/Containerfile.rocmfpx .
```

For stable ROCm FPX llama.cpp:

```bash
buildah bud --pull --format oci --layers \
  --build-arg BUILD_TYPE=rocm-fpx \
  --build-arg LLAMA_REPO=https://github.com/charlie12345/ROCmFPX.git \
  --build-arg LLAMA_BRANCH=main \
  --build-arg LLAMA_REF=014cd28b97d539a0365979d88e9846fad5aa822b \
  -t localhost/strix-llama:rocm-fpx \
  -f containers/Containerfile.rocmfpx .
```

For ROCm nightly FPX llama.cpp:

```bash
buildah bud --pull --format oci --layers \
  --build-arg BUILD_TYPE=rocm-next-fpx \
  --build-arg LLAMA_REPO=https://github.com/charlie12345/ROCmFPX.git \
  --build-arg LLAMA_BRANCH=main \
  --build-arg LLAMA_REF=014cd28b97d539a0365979d88e9846fad5aa822b \
  --build-arg ROCM_NIGHTLY_TARBALL=therock-dist-linux-gfx1151-7.13.0a20260515.tar.gz \
  -t localhost/strix-llama:rocm-next-fpx \
  -f containers/Containerfile.rocmfpx .
```

For Vulkan:

```bash
buildah bud --pull --format oci --layers \
  --build-arg BUILD_TYPE=vulkan \
  -t localhost/strix-llama:vulkan \
  -f containers/Containerfile .
```

The Containerfiles use Buildah cache mounts for DNF packages, ROCm nightly
tarballs, and llama.cpp checkouts. Stock and ROCmFP4 builds use separate
llama.cpp source caches so the fork branch does not churn the stock worktree.
They build only the runtime targets used by the next workflow: `llama-server`,
`llama-cli`, `llama-bench`, `llama-gguf-split`, and `llama-quantize`. They also copy the shared
patch and helper assets from `toolboxes/`. Each build resets the cached
llama.cpp worktree before switching refs and applying local patches, so dirty
source files left by one backend do not break the next backend build.

`rocm-next` and `rocm-next-fp4` copy the pinned TheRock ROCm runtime from the
builder stage. The runtime images keep `/opt/rocm/share`, register
`/opt/rocm/lib/rocm_sysdeps/lib` with `ldconfig`, and expose `/opt/rocm/bin` on
`PATH`; those pieces are required for ROCm tools such as `rocminfo` to
initialize instead of failing before llama.cpp can print a useful error.

## Smoke Tests

Check the built binaries:

```bash
podman run --rm localhost/strix-llama:rocm llama-server --version
podman run --rm localhost/strix-llama:rocm-next llama-server --version
podman run --rm localhost/strix-llama:vulkan llama-server --version
podman run --rm localhost/strix-llama:vulkan-fp4 llama-server --version
podman run --rm localhost/strix-llama:rocm-fp4 llama-server --version
podman run --rm localhost/strix-llama:rocm-next-fp4 llama-server --version
podman run --rm localhost/strix-llama:vulkan-fpx llama-server --version
podman run --rm localhost/strix-llama:rocm-fpx llama-server --version
podman run --rm localhost/strix-llama:rocm-next-fpx llama-server --version
podman run --rm localhost/strix-llama:rocm-fpx llama-quantize --help
```

Check GPU visibility:

```bash
podman run --rm \
  --security-opt seccomp=unconfined \
  --security-opt label=disable \
  --group-add keep-groups \
  --device /dev/dri \
  --device /dev/kfd \
  localhost/strix-llama:rocm \
  llama-cli --list-devices

podman run --rm \
  --security-opt seccomp=unconfined \
  --security-opt label=disable \
  --group-add keep-groups \
  --device /dev/dri \
  --device /dev/kfd \
  localhost/strix-llama:rocm-next \
  llama-cli --list-devices

podman run --rm \
  --security-opt seccomp=unconfined \
  --security-opt label=disable \
  --group-add keep-groups \
  --device /dev/dri \
  localhost/strix-llama:vulkan-fp4 \
  llama-cli --list-devices

podman run --rm \
  --security-opt seccomp=unconfined \
  --security-opt label=disable \
  --group-add keep-groups \
  --device /dev/dri \
  --device /dev/kfd \
  --env HSA_OVERRIDE_GFX_VERSION=11.5.1 \
  --env GGML_HIP_ENABLE_UNIFIED_MEMORY=1 \
  localhost/strix-llama:rocm-fp4 \
  llama-cli --list-devices

podman run --rm \
  --security-opt seccomp=unconfined \
  --security-opt label=disable \
  --group-add keep-groups \
  --device /dev/dri \
  --device /dev/kfd \
  --env HSA_OVERRIDE_GFX_VERSION=11.5.1 \
  --env GGML_HIP_ENABLE_UNIFIED_MEMORY=1 \
  localhost/strix-llama:rocm-next-fp4 \
  llama-cli --list-devices

podman run --rm \
  --security-opt seccomp=unconfined \
  --security-opt label=disable \
  --group-add keep-groups \
  --device /dev/dri \
  --device /dev/kfd \
  --env HSA_OVERRIDE_GFX_VERSION=11.5.1 \
  --env GGML_HIP_ENABLE_UNIFIED_MEMORY=1 \
  localhost/strix-llama:rocm-fpx \
  llama-cli --list-devices

podman run --rm \
  --security-opt seccomp=unconfined \
  --security-opt label=disable \
  --group-add keep-groups \
  --device /dev/dri \
  localhost/strix-llama:vulkan-fpx \
  llama-cli --list-devices

podman run --rm \
  --security-opt seccomp=unconfined \
  --security-opt label=disable \
  --group-add keep-groups \
  --device /dev/dri \
  --device /dev/kfd \
  --env HSA_OVERRIDE_GFX_VERSION=11.5.1 \
  --env GGML_HIP_ENABLE_UNIFIED_MEMORY=1 \
  localhost/strix-llama:rocm-next-fpx \
  llama-cli --list-devices

podman run --rm \
  --security-opt seccomp=unconfined \
  --security-opt label=disable \
  --group-add keep-groups \
  --device /dev/dri \
  localhost/strix-llama:vulkan \
  llama-cli --list-devices
```

Check model-load without leaving a server running:

```bash
bin/run.sh rocm load-test /var/mnt/xdata/models/qwen/model.gguf
```

`load-test` starts `llama-server` detached, waits for the model-loaded log line,
prints the last server logs, and stops the container. Use
`LLAMA_LOAD_TEST_TIMEOUT=180` for very large models.
