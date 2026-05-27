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
  LLAMA_ROCM_REF     llama.cpp ref for stable ROCm. Default: 95405ac65
  CPU_TARGET         generic, strix-halo, or native. Default: generic
  TAG_VERSION        Also tag stable ROCm as rocm-$ROCM_VERSION. Default: 1
  TAG_NIGHTLY_ALIAS  Also tag rocm-next as rocm7-nightlies. Default: 1
  BUILD_CACHE_REPO   Optional remote registry repo prefix for Buildah cache
  BUILD_LOG_MODE     progress or full. Default: progress
  BUILD_LOG_DIR      Directory for full build logs. Default: .build-logs
  BUILD_LOG_TAIL     Full-log lines to print on failure. Default: 160
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
LLAMA_ROCM_REF="${LLAMA_ROCM_REF:-95405ac65}"
CPU_TARGET="${CPU_TARGET:-generic}"
TAG_VERSION="${TAG_VERSION:-1}"
TAG_NIGHTLY_ALIAS="${TAG_NIGHTLY_ALIAS:-1}"
BUILD_LOG_MODE="${BUILD_LOG_MODE:-progress}"
BUILD_LOG_DIR="${BUILD_LOG_DIR:-.build-logs}"
BUILD_LOG_TAIL="${BUILD_LOG_TAIL:-160}"
DRY_RUN="${DRY_RUN:-0}"

case "$BUILDER" in
  buildah|podman) ;;
  *)
    echo "Unsupported BUILDER: $BUILDER" >&2
    usage
    exit 1
    ;;
esac

case "$BUILD_LOG_MODE" in
  progress|full) ;;
  *)
    echo "Unsupported BUILD_LOG_MODE: $BUILD_LOG_MODE" >&2
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
  local cache_args=()
  local cmd=()

  if [[ -n "${BUILD_CACHE_REPO:-}" ]]; then
    cache_args=(
      --cache-from "$BUILD_CACHE_REPO/$build_type-$CPU_TARGET"
      --cache-to "$BUILD_CACHE_REPO/$build_type-$CPU_TARGET"
    )
  fi

  case "$build_type" in
    rocm)
      if [[ "$CPU_TARGET" == "generic" ]]; then
        tag_args=(-t "$IMAGE_PREFIX:rocm")
        if [[ "$TAG_VERSION" == "1" ]]; then
          tag_args+=(-t "$IMAGE_PREFIX:rocm-$ROCM_VERSION")
        fi
      else
        tag_args+=(-t "$IMAGE_PREFIX:rocm-$CPU_TARGET")
        if [[ "$TAG_VERSION" == "1" ]]; then
          tag_args+=(-t "$IMAGE_PREFIX:rocm-$ROCM_VERSION-$CPU_TARGET")
        fi
      fi
      ;;
    rocm-next)
      if [[ "$CPU_TARGET" == "generic" ]]; then
        tag_args=(-t "$IMAGE_PREFIX:rocm-next")
        if [[ "$TAG_NIGHTLY_ALIAS" == "1" ]]; then
          tag_args+=(-t "$IMAGE_PREFIX:rocm7-nightlies")
        fi
      else
        tag_args+=(-t "$IMAGE_PREFIX:rocm-next-$CPU_TARGET")
        if [[ "$TAG_NIGHTLY_ALIAS" == "1" ]]; then
          tag_args+=(-t "$IMAGE_PREFIX:rocm7-nightlies-$CPU_TARGET")
        fi
      fi
      ;;
    vulkan)
      if [[ "$CPU_TARGET" == "generic" ]]; then
        tag_args=(-t "$IMAGE_PREFIX:vulkan")
      else
        tag_args=(-t "$IMAGE_PREFIX:vulkan-$CPU_TARGET")
      fi
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
      --build-arg "LLAMA_ROCM_REF=$LLAMA_ROCM_REF" \
      --build-arg "CPU_TARGET=$CPU_TARGET" \
      "${cache_args[@]}" \
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
      --build-arg "LLAMA_ROCM_REF=$LLAMA_ROCM_REF" \
      --build-arg "CPU_TARGET=$CPU_TARGET" \
      "${cache_args[@]}" \
      "${tag_args[@]}" \
      -f "$CONTAINERFILE" \
      "${BUILD_EXTRA[@]}" \
      .)
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    printf '  %q' "${cmd[@]}"
    printf '\n'
  elif [[ "$BUILD_LOG_MODE" == "full" ]]; then
    "${cmd[@]}"
  else
    mkdir -p "$BUILD_LOG_DIR"
    local started_at
    local log_file
    started_at="$(date +%Y%m%d-%H%M%S)"
    log_file="$BUILD_LOG_DIR/${started_at}-${build_type}-${CPU_TARGET}.log"
    printf 'Full build log: %s\n' "$log_file"

    set +e
    "${cmd[@]}" 2>&1 | tee "$log_file" | awk '
      cmake_warning_context > 0 {
        print; fflush();
        cmake_warning_context--;
        next
      }
      /^>>> Already downloaded$/ { next }
      /^STEP [0-9]+\/[0-9]+:/ { print; fflush(); next }
      /^>>> / { print; fflush(); next }
      /^Latest ROCm nightly tarball:/ { print; fflush(); next }
      /^COMMIT / { print; fflush(); next }
      /^Successfully tagged / { print; fflush(); next }
      /^CMake Warning/ { print; fflush(); cmake_warning_context = 8; next }
      /[Ww]arning:/ { print; fflush(); next }
      /^Error: / { print; fflush(); next }
      /^error: / { print; fflush(); next }
      /^CMake Error/ { print; fflush(); next }
      /^fatal: / { print; fflush(); next }
      /FAILED:/ { print; fflush(); next }
      /^ninja: / { print; fflush(); next }
      /No such file or directory/ { print; fflush(); next }
    '
    local status=${PIPESTATUS[0]}
    set -e

    if [[ "$status" -ne 0 ]]; then
      printf 'Build failed for %s. Last %s lines from %s:\n' "$build_type" "$BUILD_LOG_TAIL" "$log_file" >&2
      tail -n "$BUILD_LOG_TAIL" "$log_file" >&2
      return "$status"
    fi
  fi
}

cd "$PROJECT_ROOT"

for target in "${TARGETS[@]}"; do
  build_image "$target"
done
