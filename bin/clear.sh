#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bin/clear.sh [--cache] [--containers] [--images] [--logs] [--all] [--dry-run]

Default:
  With no cleanup flags, clears --cache, --containers, and --images.

Environment:
  BUILDER        buildah or podman. Default: buildah
  IMAGE_PREFIX   Image repository prefix. Default: localhost/strix-llama
  BUILD_LOG_DIR  Directory for full build logs. Default: .build-logs
  DRY_RUN        Print cleanup commands without running them. Default: 0

Examples:
  bin/clear.sh
  bin/clear.sh --cache
  bin/clear.sh --images --logs
  BUILDER=podman bin/clear.sh --dry-run
EOF
}

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/bin/env-defaults.sh"
load_dotenv_defaults "$PROJECT_ROOT/.env"

BUILDER="${BUILDER:-buildah}"
IMAGE_PREFIX="${IMAGE_PREFIX:-localhost/strix-llama}"
BUILD_LOG_DIR="${BUILD_LOG_DIR:-.build-logs}"
DRY_RUN="${DRY_RUN:-0}"

CLEAR_CACHE=0
CLEAR_CONTAINERS=0
CLEAR_IMAGES=0
CLEAR_LOGS=0
SAW_CLEANUP_FLAG=0

case "$BUILDER" in
  buildah|podman) ;;
  *)
    echo "Unsupported BUILDER: $BUILDER" >&2
    usage
    exit 1
    ;;
esac

run_cmd() {
  printf '  %q' "$@"
  printf '\n'

  if [[ "$DRY_RUN" == "1" ]]; then
    return 0
  fi

  "$@"
}

load_images() {
  local -n images_ref="$1"
  local image_format
  local image_list

  if [[ "$BUILDER" == "buildah" ]]; then
    image_format='{{.Name}}:{{.Tag}}'
  else
    image_format='{{.Repository}}:{{.Tag}}'
  fi

  image_list="$("$BUILDER" images --format "$image_format")"
  # shellcheck disable=SC2034
  mapfile -t images_ref < <(
    awk -v prefix="$IMAGE_PREFIX" \
      'index($0, prefix ":") == 1 && $0 !~ /:<none>$/ { print }' \
      <<< "$image_list"
  )
}

clear_cache() {
  echo "Clearing builder caches for $BUILDER"

  if [[ "$BUILDER" == "buildah" ]]; then
    run_cmd buildah prune --all --force
  else
    run_cmd podman builder prune --all --force
  fi
}

clear_containers() {
  local containers=()
  local images=()
  local container_list
  local image

  echo "Clearing build containers for $BUILDER"

  if [[ "$BUILDER" == "buildah" ]]; then
    run_cmd buildah rm --all
    return 0
  fi

  load_images images

  for image in "${images[@]}"; do
    container_list="$(podman ps -a --filter "ancestor=$image" --format '{{.ID}}')"
    while IFS= read -r container; do
      [[ -n "$container" ]] && containers+=("$container")
    done <<< "$container_list"
  done

  if [[ "${#containers[@]}" -eq 0 ]]; then
    echo "  no containers found for images under $IMAGE_PREFIX"
    return 0
  fi

  run_cmd podman rm --force "${containers[@]}"
}

clear_images() {
  local images=()

  echo "Clearing images under $IMAGE_PREFIX"

  load_images images

  if [[ "${#images[@]}" -eq 0 ]]; then
    echo "  no images found"
    return 0
  fi

  run_cmd "$BUILDER" rmi --force "${images[@]}"
}

clear_logs() {
  echo "Clearing build logs from $BUILD_LOG_DIR"

  if [[ ! -e "$BUILD_LOG_DIR" ]]; then
    echo "  no log directory found"
    return 0
  fi

  run_cmd rm -rf "$BUILD_LOG_DIR"
}

for arg in "$@"; do
  case "$arg" in
    -h|--help)
      usage
      exit 0
      ;;
    --cache)
      CLEAR_CACHE=1
      SAW_CLEANUP_FLAG=1
      ;;
    --containers)
      CLEAR_CONTAINERS=1
      SAW_CLEANUP_FLAG=1
      ;;
    --images)
      CLEAR_IMAGES=1
      SAW_CLEANUP_FLAG=1
      ;;
    --logs)
      CLEAR_LOGS=1
      SAW_CLEANUP_FLAG=1
      ;;
    --all)
      CLEAR_CACHE=1
      CLEAR_CONTAINERS=1
      CLEAR_IMAGES=1
      SAW_CLEANUP_FLAG=1
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    *)
      echo "Unknown option: $arg" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "$SAW_CLEANUP_FLAG" == "0" ]]; then
  CLEAR_CACHE=1
  CLEAR_CONTAINERS=1
  CLEAR_IMAGES=1
fi

cd "$PROJECT_ROOT"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "Dry run: no cleanup commands will be executed"
fi

[[ "$CLEAR_CONTAINERS" == "1" ]] && clear_containers
[[ "$CLEAR_IMAGES" == "1" ]] && clear_images
[[ "$CLEAR_CACHE" == "1" ]] && clear_cache
[[ "$CLEAR_LOGS" == "1" ]] && clear_logs

exit 0
