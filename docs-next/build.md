# Building Next-Workflow Images

Build from the repository root. The next workflow uses one Containerfile for
ROCm and Vulkan images and selects the build with `BUILD_TYPE`.

## Quick Start

Build all next-workflow images:

```bash
bin/build
```

Build one image:

```bash
bin/build rocm-7.2.3
bin/build rocm7-nightlies
bin/build vulkan-radv
```

The default tags are:

| Target | Image |
| :--- | :--- |
| `rocm-7.2.3` | `localhost/amd-strix-halo-toolboxes:rocm-7.2.3-next` |
| `rocm7-nightlies` | `localhost/amd-strix-halo-toolboxes:rocm7-nightlies-next` |
| `vulkan-radv` | `localhost/amd-strix-halo-toolboxes:vulkan-radv-next` |

## Build Script

`bin/build` uses Buildah by default:

```bash
bin/build rocm-7.2.3
```

Use Podman instead:

```bash
BUILDER=podman bin/build rocm7-nightlies
```

Override the image prefix:

```bash
IMAGE_PREFIX=localhost/strix-halo bin/build rocm-7.2.3
```

Pass advanced build flags with `BUILD_EXTRA_ARGS`:

```bash
BUILD_EXTRA_ARGS="--no-cache" bin/build rocm-7.2.3
```

## Manual Build

The script expands to commands like this:

```bash
buildah bud --pull --format oci --layers \
  --build-arg BUILD_TYPE=rocm-7.2.3 \
  -t localhost/amd-strix-halo-toolboxes:rocm-7.2.3-next \
  -f containers/Containerfile .
```

For nightly ROCm:

```bash
buildah bud --pull --format oci --layers \
  --build-arg BUILD_TYPE=rocm7-nightlies \
  -t localhost/amd-strix-halo-toolboxes:rocm7-nightlies-next \
  -f containers/Containerfile .
```

For Vulkan RADV:

```bash
buildah bud --pull --format oci --layers \
  --build-arg BUILD_TYPE=vulkan-radv \
  -t localhost/amd-strix-halo-toolboxes:vulkan-radv-next \
  -f containers/Containerfile .
```

The Containerfile uses Buildah cache mounts for DNF packages, ROCm nightly
tarballs, and the shared llama.cpp checkout. It also copies the shared patch and
helper assets from `toolboxes/`.

## Smoke Tests

Check the built binaries:

```bash
podman run --rm localhost/amd-strix-halo-toolboxes:rocm-7.2.3-next llama version
podman run --rm localhost/amd-strix-halo-toolboxes:rocm7-nightlies-next llama version
podman run --rm localhost/amd-strix-halo-toolboxes:vulkan-radv-next llama version
```

Check GPU visibility:

```bash
podman run --rm \
  --security-opt seccomp=unconfined \
  --security-opt label=disable \
  --group-add keep-groups \
  --device /dev/dri \
  --device /dev/kfd \
  localhost/amd-strix-halo-toolboxes:rocm-7.2.3-next \
  llama-cli --list-devices

podman run --rm \
  --security-opt seccomp=unconfined \
  --security-opt label=disable \
  --group-add keep-groups \
  --device /dev/dri \
  --device /dev/kfd \
  localhost/amd-strix-halo-toolboxes:rocm7-nightlies-next \
  llama-cli --list-devices

podman run --rm \
  --security-opt seccomp=unconfined \
  --security-opt label=disable \
  --group-add keep-groups \
  --device /dev/dri \
  localhost/amd-strix-halo-toolboxes:vulkan-radv-next \
  llama-cli --list-devices
```
