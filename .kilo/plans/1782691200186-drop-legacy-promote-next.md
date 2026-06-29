# Plan: Drop Legacy Upstream, Promote `next` to Default

## Goal

Remove every upstream/legacy Toolbx–Distrobox artifact from this fork and make the
raw Podman/Docker `next` workflow the sole, default workflow. Rename/relayout files
so `next` paths become the canonical paths, and fold the Strix Halo **hardware**
focus (host config, firmware, VRAM) into the new docs so it is not lost.

No source rewrite of build/runtime logic — only relocation, deletion, doc
merging, CI replacement, and wording cleanup. llama.cpp build/run behavior stays
identical.

## Locked Decisions

1. Shared build assets move to new `patches/` + `scripts/` dirs (not into `containers/`).
2. Benchmark runner scripts are kept; result data and `run_distributed_llama.py` are dropped.
3. Legacy CI is replaced by a new next-workflow CI that drives `bin/build.sh` (+ push to GHCR, + adapted llama.cpp poller).
4. `AGENTS.override.md` is collapsed into a single `AGENTS.md`; override file deleted.
5. `docs-next/` becomes `docs/`; legacy GitHub Pages site and legacy docs are dropped; a dedicated `docs/hardware.md` consolidates Strix Halo hardware/host-config/firmware/VRAM content.

## File Fate (exhaustive)

### Move
| From | To |
| :-- | :-- |
| `toolboxes/llama-grammar.patch` | `patches/llama-grammar.patch` |
| `toolboxes/gguf-vram-estimator.py` | `scripts/gguf-vram-estimator.py` |
| `docs-next/build.md` | `docs/build.md` |
| `docs-next/intent-and-delta.md` | rewritten as `docs/overview.md` (content rewrite; see Phase 3) |
| `docs-next/llama-cpp-args.md` | `docs/llama-cpp-args.md` |
| `docs-next/llama-cpp-targets.md` | `docs/llama-cpp-targets.md` |
| `docs-next/podman.md` | `docs/podman.md` |
| `docs-next/rocmfpx-fork.md` | `docs/rocmfpx-fork.md` |
| `docs-next/unsloth-qwen-3_6.md` | `docs/unsloth-qwen-3_6.md` |
| `README-next.md` content | merged into rewritten `README.md` (then delete `README-next.md`) |

### New / rewrite
| Path | Source / content |
| :-- | :-- |
| `README.md` | Merge `README-next.md` workflow content + Strix Halo intro + host-config summary from legacy `README.md`; doc index pointing into `docs/`. |
| `docs/hardware.md` | Consolidate: legacy `README.md` Stable/Host Config + Test Config, `docs/troubleshooting-firmware.md`, `docs/vram-estimator.md`. Lean. |
| `docs/overview.md` | Rewrite of `intent-and-delta.md`: repo layout, build/runtime data flow, container targets table. Drop all "since fork" / "legacy boundary" language. |
| `AGENTS.md` | Collapse `AGENTS.override.md` into it; update the Documentation Rule paths. |
| `.github/workflows/build.yml` | New next-workflow CI (matrix → `bin/build.sh`, push GHCR, smoke). |

### Delete — legacy
| Path | Reason |
| :-- | :-- |
| `toolboxes/Dockerfile.*` (×7) | Legacy Toolbx builds. |
| `toolboxes/ggml/src/ggml-cuda/hip_shfl_fix.h` | Orphan; no consumer in any Dockerfile/Containerfile/script/doc. |
| `toolboxes/hip-rocm7rc.patch` | Orphan; zero references in tree. |
| `refresh-toolboxes.sh` | Legacy toolbox refresh. |
| `README-next.md` | Folded into `README.md`. |
| `AGENTS.override.md` | Collapsed into `AGENTS.md`. |
| `docs/index.html`, `docs/mtp.html`, `docs/assets/*` | Legacy GitHub Pages site (strix-halo-toolboxes.com). |
| `docs/results.json` | Feeds dropped site. |
| `docs/models.ini.example` | Legacy router example; next uses `models-template.ini`. |
| `docs/building.md`, `docs/docker-compose-how-to.md` | Legacy building/compose guides (reference `toolboxes/`). |
| `docs/troubleshooting-firmware.md`, `docs/vram-estimator.md` | Content ported into `docs/hardware.md` first, then deleted. |
| `.github/workflows/build_and_publish.yml` | Legacy toolboxes build. |
| `.github/workflows/prune-old-toolboxes.yml` | Legacy DockerHub prune. |
| `.github/workflows/poll-llama-cpp.yaml` | Replaced by adapted poller. |
| `.github/ISSUE_TEMPLATE/bug_report.md` | Upstream-author template. |
| `scripts/run_distributed_llama.py`, `scripts/__pycache__/` | Legacy RPC distributed; next intentionally disables RPC. |
| `benchmark/results/`, `benchmark/results-rpc/`, `benchmark/results-mtp/` | Historical result data. |
| `benchmark/generate_results_json.py` | Orphaned: wrote `../docs/results.json` for the dropped site. |

### Keep (unchanged)
`containers/Containerfile`, `containers/Containerfile.rocmfpx`, `containers/rocmfpx-warning.patch`,
`containers/.gitkeep`, `bin/*`, `models-template.ini`, `.env`, `.gitignore`,
`.shellcheckrc`, `coding-tool-configs/`, `.agents/`, `.codex/`,
`benchmark/run_benchmarks.sh`, `benchmark/run_rpc_benchmarks.sh`,
`benchmark/mtp-bench.py`, `benchmark/run_mtp_bench.py`.

### Edit in place
- `containers/Containerfile` + `containers/Containerfile.rocmfpx`: fix 2×2 `COPY` paths (`toolboxes/...` → `patches/...` and `scripts/...`).
- `docs/build.md`: update prose "copy the shared patch and helper assets from `toolboxes/`" → new locations; scrub "next-workflow".
- `benchmark/run_mtp_bench.py`: rewire hardcoded `docker.io/kyuz0/amd-strix-halo-toolboxes:*` image refs to `localhost/strix-llama:*` (or `IMAGE_PREFIX`-driven).

---

## Phases

### Phase 0 — Safety net
- Confirm `git status` clean; working tree matches `origin/main`.
- Create migration branch, e.g. `git checkout -b drop-legacy-promote-next`.
- Keep `upstream` remote for historical reference. **Do not rewrite history** — use ordinary deletions/commits.
- Optional: tag current HEAD (e.g. `legacy-upstream-snapshot`) as a recovery point.

### Phase 1 — Relocate shared build assets (must keep builds green)
Order matters: move before deleting `toolboxes/`.
1. `git mv toolboxes/llama-grammar.patch patches/llama-grammar.patch` (create `patches/`).
2. `git mv toolboxes/gguf-vram-estimator.py scripts/gguf-vram-estimator.py`.
3. Edit `containers/Containerfile`: `COPY toolboxes/llama-grammar.patch` → `COPY patches/llama-grammar.patch`; `COPY toolboxes/gguf-vram-estimator.py` → `COPY scripts/gguf-vram-estimator.py`.
4. Same two edits in `containers/Containerfile.rocmfpx`.
5. Update `docs-next/build.md` prose line referencing "assets from `toolboxes/`".
6. Validate: `DRY_RUN=1 bin/build.sh all` prints correct `-f`/context with new paths; optionally run one real `bin/build.sh vulkan` to confirm `COPY` resolves.

### Phase 2 — Promote next docs + rewrite README + collapse AGENTS
1. `git mv` each `docs-next/*.md` into `docs/` (no name collisions with legacy docs).
2. Rewrite `README.md` from `README-next.md` content + Strix Halo intro + a short host-config summary that links to `docs/hardware.md`; add a doc index linking `docs/{overview,build,podman,llama-cpp-args,llama-cpp-targets,rocmfpx-fork,hardware}.md`. Drop upstream-personal content (buy-me-a-coffee, YouTube, DockerHub `kyuz0` links).
3. Delete `README-next.md`.
4. Collapse `AGENTS.override.md` into `AGENTS.md` (single agent doc). Update the Documentation Rule path list to the new names:
   `README.md`, `docs/overview.md`, `docs/build.md`, `docs/podman.md`, `docs/llama-cpp-args.md`, plus `docs/hardware.md` for hardware/host-config changes. Delete `AGENTS.override.md`.

### Phase 3 — Author consolidated hardware + overview docs
1. Create `docs/hardware.md` by porting (lean) from legacy `README.md` (Stable Config: OS/kernel/firmware, incl. "avoid kernels < 6.18.4" and "do NOT use linux-firmware-20251125"; Host Configuration: kernel params `amd_iommu=off amdgpu.gttsize=126976 ttm.pages_limit=32505856`, table + grub apply + Ubuntu note; Test Configuration table), `docs/troubleshooting-firmware.md` (firmware downgrade steps), and `docs/vram-estimator.md` (usage; note tool now at `scripts/gguf-vram-estimator.py` and baked into the image).
2. Create `docs/overview.md` by rewriting the moved `intent-and-delta.md`: repo layout (`containers/`, `bin/`, `patches/`, `scripts/`, `docs/`, `benchmark/`), build→run data flow, container targets table (rocm/rocm-next/vulkan/vulkan-fpx/rocm-fpx/rocm-next-fpx). Remove all "next-workflow", "legacy upstream", "since fork", "legacy boundary" phrasing.
3. Delete `docs/intent-and-delta.md`.

### Phase 4 — Delete all legacy files
Delete everything in the **Delete — legacy** table. Sequencing note: ensure Phase 3 ported `troubleshooting-firmware.md` + `vram-estimator.md` content into `docs/hardware.md` before deleting them.
- Rewire `benchmark/run_mtp_bench.py` image refs to `localhost/strix-llama:*` (or make `IMAGE_PREFIX`-driven) so the kept benchmark script targets next images.

### Phase 5 — Scrub wording + fix cross-links (repo-wide sweep)
- Remove "next-workflow / legacy / upstream / fork / docs-next / README-next / AGENTS.override" wording across `docs/*.md`, `bin/*`, `containers/*`, `README.md`, `AGENTS.md`.
- Fix all doc cross-links (e.g. README `docs-next/...` → `docs/...`; relative links inside `docs/` stay valid).
- `docs/build.md`: scrub "Building Next-Workflow Images" title → default build title; ensure asset-path text matches Phase 1.
- `docs/podman.md`: ensure it reads as the primary (not "without Toolbx") runtime doc.

### Phase 6 — CI
1. Delete `.github/workflows/build_and_publish.yml`, `prune-old-toolboxes.yml`, `poll-llama-cpp.yaml`, and `.github/ISSUE_TEMPLATE/`.
2. Add `.github/workflows/build.yml`:
   - Triggers: `workflow_dispatch` (backends input, default `rocm rocm-next vulkan`), and `workflow_run` from the poller.
   - Install buildah on `ubuntu-latest` (builds only **compile** for `gfx1151`; no AMD GPU needed at build time), set `BUILDER=buildah`.
   - Matrix over selected backends → `bin/build.sh <backend>` with `IMAGE_PREFIX=ghcr.io/${{ github.repository_owner }}/strix-llama`.
   - Push to GHCR when secrets present; smoke: `podman run --rm <image> llama-server --version` (+ `--list-devices` is GPU-dependent, skip on CI).
   - Use `BUILD_CACHE_REPO` / registry cache for speed.
3. Add an adapted `.github/workflows/poll-llama-cpp.yml` that, on llama.cpp master SHA change, dispatches `build.yml` (replace the old `build_and_publish.yml` dispatch + inputs shape).

### Phase 7 — Validation
- `shellcheck bin/*.sh` (respect `.shellcheckrc`).
- `DRY_RUN=1 bin/build.sh all` — confirm all targets resolve with new asset paths and no `toolboxes/` refs.
- Dangling-reference grep returns nothing: `toolboxes/`, `docs-next`, `refresh-toolboxes`, `README-next`, `AGENTS.override`, `kyuz0/amd-strix-halo-toolboxes`, `run_distributed_llama`, `generate_results_json`.
- Doc-link check: every `docs/...` / `README.md` link resolves to a present file.
- `git ls-files` review: no legacy paths remain; `patches/`, `scripts/gguf-vram-estimator.py`, `docs/hardware.md`, `docs/overview.md`, `.github/workflows/build.yml` present.
- Confirm `models-template.ini`, `containers/*`, `bin/*` behavior unchanged (diff is only path/text).

## Risks
- **Phase 1 vs Phase 4 ordering**: the 4 `COPY` path edits MUST land before `toolboxes/` deletion, or all builds break. Phase 1 is gated on a `DRY_RUN`/single-build check.
- **`generate_results_json.py` orphaning**: deleting it is correct only because the site + results data are also dropped; if benchmark results are ever regenerated into a new viewer, this script (or equivalent) must be re-added.
- **CI buildah cache mounts**: require buildah/podman installed on the runner; `docker build` is not supported by `bin/build.sh` (only `buildah`/`podman`). Confirm before relying on cache-mount layers.
- **`run_mtp_bench.py` rewiring**: if not rewired, the kept script still references legacy `kyuz0/...` images.
- **AGENTS collapse**: any external tooling/config that points at `AGENTS.override.md` must be updated to `AGENTS.md` (the global/local config that says "use AGENTS.override.md first").

## Out of scope
- Rewriting llama.cpp build flags, runtime defaults, or `models-template.ini` behavior.
- Re-implementing distributed/RPC inference (explicitly disabled in next).
- Designing a new results viewer to replace the dropped GitHub Pages site.
- Touching git history or the `upstream` remote beyond keeping it for reference.
