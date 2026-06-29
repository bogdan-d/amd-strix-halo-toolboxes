# AMD Strix Halo llama.cpp Containers

Pre-built, Podman/Docker-compatible containers for running [llama.cpp] on **AMD
Ryzen AI Max "Strix Halo"** (gfx1151) integrated GPUs. They expose the APU's
unified memory, so a single image can serve large models using up to **124 GiB**
of system RAM as GPU memory, across ROCm and Vulkan backends.

> **Critical on Strix Halo:** every `llama-server` / `llama-cli` invocation needs
> **flash attention** (`-fa 1`) and **`--no-mmap`**; without them, memory
> fragmentation causes crashes and slowdowns. The `bin/run.sh` helper applies
> these (and the rest of the measured Strix Halo defaults) for you. See
> [docs/llama-cpp-args.md](docs/llama-cpp-args.md) for the full argument map.

## Host configuration

Strix Halo needs kernel boot parameters to hand unified memory to the iGPU:

```
amd_iommu=off amdgpu.gttsize=126976 ttm.pages_limit=32505856
```

Also avoid kernels older than **6.18.4** and the broken `linux-firmware-20251125`
package. Full setup — firmware selection, the grub apply step, Ubuntu notes, and
VRAM planning — lives in [docs/hardware.md](docs/hardware.md).

## Quick start

`bin/run.sh` wraps `podman run` with the correct device mounts (`/dev/dri`,
`/dev/kfd`), the Strix Halo defaults, and automatic model discovery.

```bash
export MODELS_DIR=/path/to/your/models

# confirm the iGPU is visible inside the container
bin/run.sh rocm list-devices

# list the discovered model IDs
bin/run.sh rocm models

# start an OpenAI-compatible server (auto-builds a models preset)
bin/run.sh rocm server
```

By default `server` generates a temporary llama.cpp `--models-preset` from the
tracked `models-template.ini` plus the GGUF files found under `MODELS_DIR`;
clients select a model by its provider-qualified preset name. Preset runs take
their remaining defaults from `models-template.ini`: flash attention on, `mmap`
off, full GPU offload, ~262k total context across four slots, q8_0 KV cache, and
MTP settings for detected MTP models.

**Backend names:** `vulkan`, `rocm`, `rocm-7.2.4`, `rocm-next`
(`rocm7-nightlies`), plus the experimental ROCmFPX forks `vulkan-fpx`,
`rocm-fpx`, and `rocm-next-fpx`. When `CPU_TARGET` is set (e.g.
`CPU_TARGET=strix-halo`), the helper resolves the matching CPU-targeted tag
automatically.

### Coding-tool configs

```bash
bin/generate-models-preset.sh --with-non-reasoning --with-vision --with-configs \
  "$MODELS_DIR" /root/models models-template.ini /tmp/llama-models.ini
```

writes Kilo Code, OpenCode, Pi, and VS Code config files under
`coding-tool-configs/`. Set `UPDATE_CONFIGS=1` in `.env` (or the environment) to
auto-merge the generated configs into your existing user config files.

### Bounded load smoke test

```bash
bin/run.sh rocm load-test "$MODELS_DIR/qwen/model.gguf"
```

starts `llama-server`, waits for the model to load, then stops the container.

### Multi-token-prediction (MTP) builds

```bash
bin/run.sh vulkan mtp-server "$MODELS_DIR/qwen-mtp/model.gguf" 3
```

## Building

Images build with Buildah through `bin/build.sh` (it defaults to `buildah`; set
`BUILDER=podman` to use Podman):

```bash
bin/build.sh all            # rocm, rocm-next, vulkan
bin/build.sh vulkan         # a single target
DRY_RUN=1 bin/build.sh all  # print the build commands only
```

See [docs/build.md](docs/build.md) for build arguments, Buildah cache behavior,
and the full target matrix (including the ROCmFPX fork targets).

## Documentation

- [Overview & repo layout](docs/overview.md)
- [Building images](docs/build.md)
- [Podman runtime workflow](docs/podman.md)
- [llama.cpp argument map](docs/llama-cpp-args.md)
- [Build target reference](docs/llama-cpp-targets.md)
- [ROCmFPX fork notes](docs/rocmfpx-fork.md)
- [Host configuration, firmware & VRAM](docs/hardware.md)

[llama.cpp]: https://github.com/ggml-org/llama.cpp
