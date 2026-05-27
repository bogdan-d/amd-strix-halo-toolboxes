# Local Next-Workflow Notes

This file is the active agent guidance for the next workflow. `AGENTS.md` below its top handoff section is legacy upstream context.

## Intent

This repo is a local continuation of the upstream AMD Strix Halo toolbox project.
Upstream is still legacy Toolbx/Distrobox-first. The local next direction is to
make raw Podman/Docker-compatible llama.cpp containers the primary workflow for
Strix Halo experiments and eventual day-to-day use.

When making changes here, optimize for:

- reproducible image builds over one-off local tweaks;
- plain Podman/Docker compatibility over Toolbx/Distrobox assumptions;
- Strix Halo runtime defaults that reflect measured local behavior;
- keeping upstream-aligned files easy to rebase until a change is deliberately
  promoted upstream.

## Repository Direction

The current upstream project is legacy Toolbx/Distrobox-first. Keep those files easy to rebase against upstream:

- `README.md`
- `toolboxes/`
- `refresh-toolboxes.sh`
- `.github/workflows/`
- existing `docs/`

The new local direction is raw Podman/Docker-compatible containers first:

- `README-next.md` documents the next workflow.
- `containers/` holds new Containerfiles and shared build assets.
- `bin/` holds host-side helper commands for raw Podman/Docker use.
- `docs-next/` holds docs for the new workflow.

## Working Rule

Prototype and iterate in the next-workflow paths. Promote changes into legacy/upstream paths only when intentionally preparing an upstream-facing patch.

Use [docs-next/intent-and-delta.md](docs-next/intent-and-delta.md) as the
high-level map of what has changed since the upstream fork.

## Documentation Rule

When implementing or updating meaningful next-workflow behavior, update the
matching docs in the same change:

- update `README-next.md` when the entry-point workflow, supported backend list,
  or first-run command path changes;
- update `docs-next/intent-and-delta.md` when the fork delta, repo direction,
  build targets, helper responsibilities, or legacy/next boundary changes;
- update `docs-next/build.md` when build targets, tags, build arguments, cache
  behavior, log behavior, or smoke tests change;
- update `docs-next/podman.md` when runtime helper commands, backend aliases,
  mounted paths, ports, environment variables, Strix Halo defaults, or raw
  Podman examples change;
- update `docs-next/llama-cpp-args.md` when this repo's llama.cpp argument
  defaults or decision guidance changes.

Small fixes do not require doc churn unless they prevent repeatedly hitting the
same mistake. If a fix captures a non-obvious local lesson, document that lesson
near the workflow it affects.
