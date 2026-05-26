#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bin/build.sh [all|rocm[=VERSION]|rocm-next|vulkan]...

Environment:
  BUILDER            buildah or podman. Default: buildah
  IMAGE_PREFIX       Image repository prefix. Default: localhost/amd-strix-halo-toolboxes
  CONTAINERFILE      Containerfile path. Default: containers/Containerfile
  ROCM_VERSION       Stable ROCm version for the rocm target. Default: 7.2.3
  TAG_VERSION        Also tag stable ROCm as rocm-$ROCM_VERSION. Default: 1
  TAG_NIGHTLY_ALIAS  Also tag rocm-next as rocm7-nightlies. Default: 1
  DRY_RUN            Print build commands without running them. Default: 0
  BUILD_EXTRA_ARGS   Extra build arguments inserted before the context

Examples:
  bin/build.sh
  bin/build.sh rocm
  bin/build.sh rocm=7.2.3
  bin/build.sh rocm-next
  bin/build.sh vulkan
  BUILDER=podman bin/build.sh all
EOF
}

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILDER="${BUILDER:-buildah}"
IMAGE_PREFIX="${IMAGE_PREFIX:-localhost/amd-strix-halo-toolboxes}"
CONTAINERFILE="${CONTAINERFILE:-containers/Containerfile}"
ROCM_VERSION="${ROCM_VERSION:-7.2.3}"
TAG_VERSION="${TAG_VERSION:-1}"
TAG_NIGHTLY_ALIAS="${TAG_NIGHTLY_ALIAS:-1}"
DRY_RUN="${DRY_RUN:-0}"

case "$BUILDER" in
  buildah|podman) ;;
  *)
    echo "Unsupported BUILDER: $BUILDER" >&2
    usage
    exit 1
    ;;
esac

if [[ $# -eq 0 ]]; then
  set -- all
fi

TARGETS=()
for target in "$@"; do
  case "$target" in
    -h|--help)
      usage
      exit 0
      ;;
    all)
      TARGETS+=(rocm rocm-next vulkan)
      ;;
    rocm|rocm-next|vulkan)
      TARGETS+=("$target")
      ;;
    rocm=*|rocm:*)
      ROCM_VERSION="${target#rocm?}"
      TARGETS+=(rocm)
      ;;
    rocm-[0-9]*.[0-9]*.[0-9]*)
      ROCM_VERSION="${target#rocm-}"
      TARGETS+=(rocm)
      ;;
    rocm-7.2.3)
      ROCM_VERSION=7.2.3
      TARGETS+=(rocm)
      ;;
    rocm7-nightlies)
      TARGETS+=(rocm-next)
      ;;
    vulkan-radv)
      TARGETS+=(vulkan)
      ;;
    *)
      echo "Unknown build target: $target" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ ! "$ROCM_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ROCM_VERSION must be major.minor.patch, got: $ROCM_VERSION" >&2
  usage
  exit 1
fi

BUILD_EXTRA=()
if [[ -n "${BUILD_EXTRA_ARGS:-}" ]]; then
  # Intentional shell splitting: this variable is for advanced build flags.
  # shellcheck disable=SC2206
  BUILD_EXTRA=(${BUILD_EXTRA_ARGS})
fi

build_image() {
  local build_type="$1"
  local rocm_repo_url="https://repo.radeon.com/rocm/rhel10/${ROCM_VERSION}/main"
  local tag_args=()
  local cmd=()

  case "$build_type" in
    rocm)
      tag_args=(-t "$IMAGE_PREFIX:rocm")
      if [[ "$TAG_VERSION" == "1" ]]; then
        tag_args+=(-t "$IMAGE_PREFIX:rocm-$ROCM_VERSION")
      fi
      ;;
    rocm-next)
      tag_args=(-t "$IMAGE_PREFIX:rocm-next")
      if [[ "$TAG_NIGHTLY_ALIAS" == "1" ]]; then
        tag_args+=(-t "$IMAGE_PREFIX:rocm7-nightlies")
      fi
      ;;
    vulkan)
      tag_args=(-t "$IMAGE_PREFIX:vulkan")
      ;;
  esac

  printf 'Building %s\n' "${tag_args[*]}"

  if [[ "$BUILDER" == "buildah" ]]; then
    cmd=("$BUILDER" bud \
      --pull \
      --format oci \
      --layers \
      --build-arg "BUILD_TYPE=$build_type" \
      --build-arg "ROCM_VERSION=$ROCM_VERSION" \
      --build-arg "ROCM_REPO_URL=$rocm_repo_url" \
      "${tag_args[@]}" \
      -f "$CONTAINERFILE" \
      "${BUILD_EXTRA[@]}" \
      .)
  else
    cmd=("$BUILDER" build \
      --pull \
      --format oci \
      --layers \
      --build-arg "BUILD_TYPE=$build_type" \
      --build-arg "ROCM_VERSION=$ROCM_VERSION" \
      --build-arg "ROCM_REPO_URL=$rocm_repo_url" \
      "${tag_args[@]}" \
      -f "$CONTAINERFILE" \
      "${BUILD_EXTRA[@]}" \
      .)
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    printf '  %q' "${cmd[@]}"
    printf '\n'
  else
    "${cmd[@]}"
  fi
}

cd "$PROJECT_ROOT"

for target in "${TARGETS[@]}"; do
  build_image "$target"
done
