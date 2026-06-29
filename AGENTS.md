# Agent Instructions

Guidance for coding agents working in this repo.

## Goal

Build and run [llama.cpp] optimally on **AMD Ryzen AI Max "Strix Halo"** (gfx1151)
integrated GPUs, using plain Podman/Docker-compatible containers that expose the
APU's unified memory (up to 124 GiB usable as GPU memory) across ROCm and Vulkan
backends. Optimize for reproducible image builds and Strix Halo runtime defaults
that reflect measured local behavior.

## Repository layout

- `containers/` — `Containerfile` (stock backends) and `Containerfile.rocmfpx`
  (ROCmFPX fork backends), plus `rocmfpx-warning.patch`.
- `bin/` — host-side helpers: `build.sh` (Buildah image builds), `run.sh`
  (Podman runtime wrapper), and preset/config generators.
- `patches/` — shared build assets copied into images (`llama-grammar.patch`).
- `scripts/` — host utilities copied into images
  (`gguf-vram-estimator.py`) and benchmark helpers.
- `docs/` — all user and contributor documentation.
- `benchmark/` — throughput/latency/MTP benchmark runner scripts.
- `.github/workflows/` — CI: image builds (`build.yml`) and the llama.cpp poller.

## Critical technical quirks

- **Flash attention & no-mmap**: every `llama-server` / `llama-cli` run on Strix
  Halo *requires* `-fa 1` and `--no-mmap` to avoid memory fragmentation and
  crashes. `bin/run.sh` applies these defaults; raw `podman run` callers must set
  them explicitly.
- **Kernel memory params**: the host needs
  `amd_iommu=off amdgpu.gttsize=126976 ttm.pages_limit=32505856` to allocate
  unified RAM to the iGPU. See `docs/hardware.md`.
- **Kernel/firmware bugs**: avoid kernels older than 6.18.4 and the broken
  `linux-firmware-20251125` package.

## Build & runtime notes

- `bin/build.sh` defaults to **buildah** (set `BUILDER=podman` for Podman). It is
  not compatible with plain `docker build` because the Containerfiles use Buildah
  cache mounts (`--mount=type=cache`).
- The Containerfiles `COPY` shared assets from `patches/` and `scripts/` (repo
  root is the build context). Keep these paths consistent when moving assets.
- Runtime images mount `/dev/dri` and `/dev/kfd` for GPU access; `bin/run.sh`
  handles this.

## Documentation rule

When implementing or updating meaningful behavior, update the matching docs in
the same change:

- `README.md` — when the entry-point workflow, supported backend list, or
  first-run command path changes.
- `docs/overview.md` — when repo layout, build/runtime data flow, or the
  container target table changes.
- `docs/build.md` — when build targets, tags, build arguments, cache behavior,
  log behavior, or smoke tests change.
- `docs/podman.md` — when runtime helper commands, backend aliases, mounted
  paths, ports, environment variables, Strix Halo defaults, or raw Podman
  examples change.
- `docs/llama-cpp-args.md` — when this repo's llama.cpp argument defaults or
  decision guidance changes.
- `docs/hardware.md` — when host configuration, kernel/firmware guidance, or
  VRAM planning changes.

Small fixes do not require doc churn unless they prevent repeatedly hitting the
same mistake. If a fix captures a non-obvious local lesson, document that lesson
near the workflow it affects.

[llama.cpp]: https://github.com/ggml-org/llama.cpp
