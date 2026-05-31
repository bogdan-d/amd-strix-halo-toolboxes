# AMD Strix Halo Containers: Next Workflow

This file tracks the experimental container workflow that should stay separate from the upstream README until it is ready to replace or extend the legacy Toolbx/Distrobox flow.

## Scope

- `containers/` is for new raw Podman/Docker-compatible Containerfiles.
- `bin/` is for host-side helper commands for the new workflow.
- `docs-next/` is for documentation that belongs to the new workflow.
- Existing `toolboxes/`, `refresh-toolboxes.sh`, and the upstream `README.md` remain legacy/upstream-aligned unless a change is intentionally promoted back.

## References

- [Next-workflow intent and fork delta](docs-next/intent-and-delta.md)
- [Build workflow](docs-next/build.md)
- [llama.cpp argument map](docs-next/llama-cpp-args.md)
- [llama.cpp target reference](docs-next/llama-cpp-targets.md)
- [Podman workflow](docs-next/podman.md)

## Podman without Toolbx or Distrobox

If you prefer plain Podman containers, use the helper script instead of creating Toolbx/Distrobox environments:

```bash
export MODELS_DIR=/var/mnt/xdata/models

bin/run.sh rocm-7.2.4 list-devices

CPU_TARGET=strix-halo bin/run.sh rocm list-devices

bin/run.sh rocm-7.2.4 models

bin/run.sh rocm-7.2.4 server
```

By default, `server` generates a temporary llama.cpp `--models-preset` from the
tracked `models-template.ini` and the GGUF files discovered under `MODELS_DIR`.
Clients select a model by its generated provider-qualified preset name.

For a bounded model-load smoke test that stops the server automatically:

```bash
bin/run.sh rocm-7.2.4 load-test \
  /var/mnt/xdata/models/qwen/model.gguf
```

Supported backend names include logical aliases such as `vulkan`, `rocm`,
`rocm-7.2.4`, `rocm-next`, and `rocm7-nightlies`, plus explicit build tags from
`bin/build.sh` such as `vulkan-strix-halo`, `rocm-strix-halo`,
`rocm-7.2.4-strix-halo`, and `rocm-next-native`. When `CPU_TARGET` is not
`generic`, `bin/run.sh rocm ...`, `bin/run.sh rocm-7.2.4 ...`,
`bin/run.sh rocm-next ...`, and `bin/run.sh vulkan ...` resolve to the matching
CPU-target tag automatically.

For MTP builds:

```bash
bin/run.sh vulkan mtp-server \
  /var/mnt/xdata/models/qwen-mtp/model.gguf \
  3
```

The helper applies the benchmark defaults for Strix Halo to direct model runs
and supplies backend-specific batch defaults for preset runs. Preset runs take
the remaining defaults from `models-template.ini`: Flash Attention, `mmap` off,
full GPU offload, 262k context with YaRN scaling from 32k, Qwen3.6
coding-agent sampling defaults, MTP settings for detected MTP models, and
`:non-reasoning` variants for Qwen-derived models.

See [docs-next/podman.md](docs-next/podman.md) for the full Podman workflow and raw `podman run` examples.
