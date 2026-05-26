# Podman without Toolbx or Distrobox

You can run the published images directly with Podman. This avoids creating Toolbx/Distrobox containers while keeping the same ROCm and Vulkan runtime images.

## Backends

The helper script supports the local next-workflow images:

| Backend | Image | GPU devices |
| :--- | :--- | :--- |
| `rocm` | `localhost/amd-strix-halo-toolboxes:rocm` | `/dev/dri`, `/dev/kfd` |
| `rocm-next` | `localhost/amd-strix-halo-toolboxes:rocm-next` | `/dev/dri`, `/dev/kfd` |
| `vulkan` | `localhost/amd-strix-halo-toolboxes:vulkan` | `/dev/dri` |

## Quick Start

Put models under `~/models`, or point `MODELS_DIR` at your model directory:

```bash
export MODELS_DIR=/var/mnt/xdata/models
```

Check GPU visibility:

```bash
bin/podman-llama.sh rocm list-devices
bin/podman-llama.sh vulkan list-devices
```

Start `llama-server`:

```bash
bin/podman-llama.sh rocm server \
  /var/mnt/xdata/models/qwen/model.gguf
```

## Local Builds

Use `bin/build.sh` to build next-workflow images from `containers/Containerfile`.
See [build.md](build.md) for build targets and smoke tests.

Start `llama-server` with draft MTP enabled:

```bash
bin/podman-llama.sh rocm mtp-server \
  /var/mnt/xdata/models/qwen-mtp/model.gguf \
  3
```

The `3` means `--spec-draft-n-max 3`. Use `2` for MTP-2.

The server listens on port `8080` by default. Override it with:

```bash
LLAMA_PORT=8081 bin/podman-llama.sh vulkan server \
  /var/mnt/xdata/models/qwen/model.gguf
```

Run `llama-cli`:

```bash
bin/podman-llama.sh rocm cli \
  /var/mnt/xdata/models/qwen/model.gguf \
  -p "Write a Strix Halo toolkit haiku."
```

Run `llama-bench`:

```bash
bin/podman-llama.sh vulkan bench \
  /var/mnt/xdata/models/qwen/model.gguf
```

## Strix Halo Defaults

The helper applies the defaults used by the benchmark scripts for this iGPU:

| Setting | Default | Source / reason |
| :--- | :--- | :--- |
| `-fa 1` | enabled | Required for reliable Strix Halo runs and used in all local benchmarks. |
| `--no-mmap` | enabled for server/CLI | Avoids mmap-related memory fragmentation and crashes. |
| `-ngl` | `999` for server/CLI, `99` for bench | Full GPU offload, matching the benchmark scripts for `llama-bench`. |
| `-c` / bench `-d` | `32768` | Long-context benchmark baseline. |
| `-b` / bench `-p` | `2048` | Long-context prompt batch size from benchmarks. |
| `-ub` Vulkan | `512` | Vulkan long-context benchmark setting. |
| `-ub` ROCm | `2048` | ROCm long-context benchmark setting. |
| `-mmp 0` | enabled for bench | Benchmark mmap-off equivalent. |

Override these with environment variables:

```bash
LLAMA_CONTEXT=65536 LLAMA_UBATCH=512 bin/podman-llama.sh vulkan server \
  /var/mnt/xdata/models/qwen/model.gguf
```

Or pass llama.cpp flags at the end; trailing flags are preserved:

```bash
bin/podman-llama.sh rocm server \
  /var/mnt/xdata/models/qwen/model.gguf \
  -c 8192 -ub 1024
```

Run an RPC worker:

```bash
bin/podman-llama.sh rocm rpc-server
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
  llama-server -m /root/models/qwen/model.gguf --host 0.0.0.0 --port 8080 \
    -c 32768 -b 2048 -ub 512 -ngl 999 -fa 1 --no-mmap
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
  -v /var/mnt/xdata/models:/root/models \
  -p 8080:8080 \
  localhost/amd-strix-halo-toolboxes:rocm \
  llama-server -m /root/models/qwen/model.gguf --host 0.0.0.0 --port 8080 \
    -c 32768 -b 2048 -ub 2048 -ngl 999 -fa 1 --no-mmap
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
    -c 32768 -b 2048 -ub 512 -ngl 999 -fa 1 --no-mmap \
    --spec-type draft-mtp --spec-draft-n-max 3 -np 1
```

## Notes

The helper always adds `-fa 1` and `--no-mmap` for `server`, `mtp-server`, and `cli` because those are required for reliable Strix Halo runs. For `bench`, it uses `-fa 1`, `-mmp 0`, `-p 2048`, `-n 32`, `-d 32768`, and the backend-specific `-ub` value.

The model path passed to `server`, `cli`, or `bench` must be under `MODELS_DIR`, because only that directory is mounted into the container.
