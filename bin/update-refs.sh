#!/usr/bin/env bash
set -euo pipefail

# Resolve the current HEAD commit of each configured llama.cpp branch and write
# it to the gitignored .env as STOCK_LLAMA_BRANCH (stock) and FPX_LLAMA_BRANCH
# (ROCmFPX fork). bin/build.sh reads these to pin builds (cache-honest,
# reproducible). Re-run to move local builds forward; the pins are local-only
# because .env is not committed.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./env-defaults.sh
source "$PROJECT_ROOT/bin/env-defaults.sh"
load_dotenv_defaults "$PROJECT_ROOT/.env"
# shellcheck source=./llama-refs.sh
source "$PROJECT_ROOT/bin/llama-refs.sh"

LLAMA_REPO="${LLAMA_REPO:-https://github.com/ggml-org/llama.cpp.git}"
LLAMA_BRANCH="${LLAMA_BRANCH:-master}"
ROCMFPX_LLAMA_REPO="${ROCMFPX_LLAMA_REPO:-https://github.com/charlie12345/ROCmFPX.git}"
ROCMFPX_LLAMA_BRANCH="${ROCMFPX_LLAMA_BRANCH:-main}"
ENV_FILE="${ENV_FILE:-$PROJECT_ROOT/.env}"

DRY_RUN="${DRY_RUN:-0}"

usage() {
  cat <<'EOF'
Usage: bin/update-refs.sh [--dry-run]

Resolve the current HEAD commit of the configured llama.cpp branches and write
them to .env as STOCK_LLAMA_BRANCH (stock) and FPX_LLAMA_BRANCH (ROCmFPX fork).
Creates .env and/or the variables if missing; updates them in place otherwise.
Other .env contents (including secrets) are preserved.

Environment:
  LLAMA_REPO            stock llama.cpp repo.   Default: ggml-org/llama.cpp
  LLAMA_BRANCH          stock branch to resolve. Default: master
  ROCMFPX_LLAMA_REPO    ROCmFPX fork repo.      Default: charlie12345/ROCmFPX
  ROCMFPX_LLAMA_BRANCH  ROCmFPX branch to resolve. Default: main
  ENV_FILE              .env path.              Default: $PROJECT_ROOT/.env

Examples:
  bin/update-refs.sh
  bin/update-refs.sh --dry-run
  bin/update-refs.sh --dry-run
EOF
}

for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "Unknown argument: $arg" >&2; usage; exit 1 ;;
  esac
done

# Upsert KEY=value in $ENV_FILE (create the file and/or variable if missing).
# value must be safe for the sed "|" delimiter (a commit sha is).
set_env_var() {
  local key="$1" value="$2"
  touch "$ENV_FILE"
  if grep -qE "^[[:space:]]*(export[[:space:]]+)?${key}=" "$ENV_FILE"; then
    sed -i -E "s|^[[:space:]]*(export[[:space:]]+)?${key}=.*|${key}=${value}|" "$ENV_FILE"
  else
    [[ -s "$ENV_FILE" && -n "$(tail -c1 "$ENV_FILE")" ]] && printf '\n' >> "$ENV_FILE"
    printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
}

current_env_value() {
  local key="$1"
  [[ -f "$ENV_FILE" ]] || return 0
  grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$ENV_FILE" 2>/dev/null \
    | tail -n1 | sed -E "s|^[[:space:]]*(export[[:space:]]+)?${key}=||" || true
}

resolve_or_die() {
  local repo="$1" branch="$2" name="$3"
  local resolved
  resolved="$(resolve_commit "$repo" "$branch")" || resolved=""
  if [[ -z "$resolved" ]]; then
    echo "error: could not resolve $name HEAD ($repo branch $branch)" >&2
    echo "       install/authorize 'gh', or ensure network + git are available." >&2
    exit 1
  fi
  printf '%s' "$resolved"
}

print_ref() {
  local label="$1" branch="$2" old="$3" new="$4" subject="$5"
  local mark
  if [[ "$old" == "$new" ]]; then mark="(unchanged)"; else mark="(changed)"; fi
  printf '  %s (%s): %s -> %s %s\n' "$label" "$branch" "${old:-<unset>}" "$new" "$mark"
  printf '      %s\n' "$subject"
}

stock_resolved="$(resolve_or_die "$LLAMA_REPO" "$LLAMA_BRANCH" "stock llama.cpp")"
stock_sha="${stock_resolved%%$'\t'*}"
stock_subject="${stock_resolved#*$'\t'}"

fpx_resolved="$(resolve_or_die "$ROCMFPX_LLAMA_REPO" "$ROCMFPX_LLAMA_BRANCH" "ROCmFPX llama.cpp")"
fpx_sha="${fpx_resolved%%$'\t'*}"
fpx_subject="${fpx_resolved#*$'\t'}"

old_stock="$(current_env_value STOCK_LLAMA_BRANCH)"
old_fpx="$(current_env_value FPX_LLAMA_BRANCH)"

echo "Resolved llama.cpp refs:"
print_ref "stock" "$LLAMA_BRANCH" "$old_stock" "$stock_sha" "$stock_subject"
print_ref "fpx  " "$ROCMFPX_LLAMA_BRANCH" "$old_fpx" "$fpx_sha" "$fpx_subject"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "(dry-run; $ENV_FILE not modified)"
  exit 0
fi

set_env_var STOCK_LLAMA_BRANCH "$stock_sha"
set_env_var FPX_LLAMA_BRANCH "$fpx_sha"
echo "Updated $ENV_FILE"
