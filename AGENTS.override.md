# Local Next-Workflow Notes

This file is the active agent guidance for the next workflow. `AGENTS.md` below its top handoff section is legacy upstream context.

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
