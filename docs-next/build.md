# Building Next-Workflow Images

Build from the repository root. The next workflow uses one Containerfile for
ROCm and Vulkan images and selects the build with `BUILD_TYPE`.

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
```

The default tags are:

| Target | Image |
| :--- | :--- |
| `rocm` | `localhost/amd-strix-halo-toolboxes:rocm` |
| `rocm-next` | `localhost/amd-strix-halo-toolboxes:rocm-next` |
| `vulkan` | `localhost/amd-strix-halo-toolboxes:vulkan` |

By default, `rocm` is also tagged as
`localhost/amd-strix-halo-toolboxes:rocm-7.2.3`, and `rocm-next` is also tagged
as `localhost/amd-strix-halo-toolboxes:rocm7-nightlies`.

## Build Script

`bin/build.sh` uses Buildah by default:

```bash
bin/build.sh rocm
bin/build.sh rocm=7.2.3
```

Use Podman instead:

```bash
BUILDER=podman bin/build.sh rocm-next
```

Override the image prefix:

```bash
IMAGE_PREFIX=localhost/strix-halo bin/build.sh rocm
```

Pass advanced build flags with `BUILD_EXTRA_ARGS`:

```bash
BUILD_EXTRA_ARGS="--no-cache" bin/build.sh rocm
```

The stable `rocm` target pins llama.cpp to `95405ac65` by default, matching the
upstream ROCm 7.2.3 toolbox image known to load models on Strix Halo. Override it
only when testing a newer llama.cpp commit:

```bash
LLAMA_ROCM_REF=master bin/build.sh rocm
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
  --build-arg ROCM_VERSION=7.2.3 \
  --build-arg ROCM_REPO_URL=https://repo.radeon.com/rocm/rhel10/7.2.3/main \
  --build-arg LLAMA_ROCM_REF=95405ac65 \
  -t localhost/amd-strix-halo-toolboxes:rocm \
  -t localhost/amd-strix-halo-toolboxes:rocm-7.2.3 \
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

For Vulkan:

```bash
buildah bud --pull --format oci --layers \
  --build-arg BUILD_TYPE=vulkan \
  -t localhost/amd-strix-halo-toolboxes:vulkan \
  -f containers/Containerfile .
```

The Containerfile uses Buildah cache mounts for DNF packages, ROCm nightly
tarballs, and the shared llama.cpp checkout. It also copies the shared patch and
helper assets from `toolboxes/`.

## Smoke Tests

Check the built binaries:

```bash
podman run --rm localhost/amd-strix-halo-toolboxes:rocm llama version
podman run --rm localhost/amd-strix-halo-toolboxes:rocm-next llama version
podman run --rm localhost/amd-strix-halo-toolboxes:vulkan llama version
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
  localhost/amd-strix-halo-toolboxes:vulkan \
  llama-cli --list-devices
```
