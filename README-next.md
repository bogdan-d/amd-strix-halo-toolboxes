# AMD Strix Halo Containers: Next Workflow

This file tracks the experimental container workflow that should stay separate from the upstream README until it is ready to replace or extend the legacy Toolbx/Distrobox flow.

## Scope

- `containers/` is for new raw Podman/Docker-compatible Containerfiles.
- `bin/` is for host-side helper commands for the new workflow.
- `docs-next/` is for documentation that belongs to the new workflow.
- Existing `toolboxes/`, `refresh-toolboxes.sh`, and the upstream `README.md` remain legacy/upstream-aligned unless a change is intentionally promoted back.

## Podman without Toolbx or Distrobox

If you prefer plain Podman containers, use the helper script instead of creating Toolbx/Distrobox environments:

```bash
export MODELS_DIR=/var/mnt/xdata/models

bin/podman-llama.sh rocm-7.2.3 list-devices

bin/podman-llama.sh rocm-7.2.3 server \
  /var/mnt/xdata/models/qwen/model.gguf
```

Supported backends are `vulkan-radv`, `vulkan-amdvlk`, `rocm-6.4.4`, `rocm-7.2.3`, `rocm7-nightlies`, `vulkan-radv-mtp`, and `rocm-7.2.3-mtp`.

For MTP builds:

```bash
bin/podman-llama.sh vulkan-radv-mtp mtp-server \
  /var/mnt/xdata/models/qwen-mtp/model.gguf \
  3
```

The helper applies the benchmark defaults for Strix Halo: `-fa 1`, `--no-mmap`, full GPU offload, 32k context, and backend-specific `-ub` values (`512` for Vulkan, `2048` for ROCm).

See [docs-next/podman.md](docs-next/podman.md) for the full Podman workflow and raw `podman run` examples.
