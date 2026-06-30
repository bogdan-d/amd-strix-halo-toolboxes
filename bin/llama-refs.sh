#!/usr/bin/env bash
# Shared helpers for resolving llama.cpp commit metadata. Sourced (not executed)
# by bin/build.sh and bin/update-refs.sh - do not add build- or .env-specific
# logic here; keep this limited to pure repo/ref -> commit resolution.

# Print "sha<TAB>subject" (first line of the commit message) for a repo+ref.
# Tries the gh CLI first for github.com URLs, then falls back to a treeless
# (commit-only) shallow git fetch that works for any git host. Empty output on
# failure; the function never aborts the caller.
resolve_commit() {
  local repo="$1"
  local ref="$2"

  if command -v gh >/dev/null 2>&1 && [[ "$repo" == *github.com/* ]]; then
    local owner_repo="${repo#*github.com/}"
    owner_repo="${owner_repo%.git}"
    if [[ "$owner_repo" == */* ]]; then
      gh api "repos/$owner_repo/commits/$ref" \
        --jq '[.sha, (.commit.message | split("\n")[0])] | @tsv' 2>/dev/null && return
    fi
  fi

  local tmp
  tmp="$(mktemp -d)" || return 0
  git -C "$tmp" init -q 2>/dev/null || { rm -rf "$tmp"; return 0; }
  if git -C "$tmp" fetch --quiet --depth 1 --filter=tree:0 "$repo" "$ref" 2>/dev/null; then
    git -C "$tmp" log -1 --format='%H%x09%s' FETCH_HEAD 2>/dev/null
  fi
  rm -rf "$tmp"
}
