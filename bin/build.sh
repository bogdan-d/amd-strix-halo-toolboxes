#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bin/build.sh [--no-cache] [--with-rocwmma] [all|rocm[=VERSION]|rocm-next|vulkan|vulkan-fp4|rocm-fp4|rocm-next-fp4|vulkan-fpx|rocm-fpx|rocm-next-fpx]...

Environment:
  BUILDER            buildah or podman. Default: buildah
  IMAGE_PREFIX       Image repository prefix. Default: localhost/strix-llama
  CONTAINERFILE      Stock Containerfile path. Default: containers/Containerfile
  ROCMFP4_CONTAINERFILE
                     ROCmFP4 Containerfile path.
                     Default: containers/Containerfile.rocmfp4
  ROCMFPX_CONTAINERFILE
                     ROCmFPX Containerfile path.
                     Default: containers/Containerfile.rocmfpx
  ROCM_VERSION       Stable ROCm version for the rocm target. Default: 7.2.4
  LLAMA_REPO         llama.cpp repository for stock backends.
                     Default: https://github.com/ggml-org/llama.cpp.git
  LLAMA_BRANCH       llama.cpp branch for stock backends. Default: master
  LLAMA_REF          llama.cpp ref for all backends. Default: empty, use LLAMA_BRANCH
  ROCMFP4_LLAMA_REPO
                     llama.cpp fork for FP4 targets.
                     Default: https://github.com/charlie12345/rocmfp4-llama.git
  ROCMFP4_LLAMA_BRANCH
                     llama.cpp fork branch for FP4 targets.
                     Default: mtp-rocmfp4-strix
  ROCMFP4_LLAMA_REF  llama.cpp fork ref for FP4 targets.
                     Default: 4795079b04f5e0ada6e5d2e85b12bac1e27e7873
  ROCMFPX_LLAMA_REPO
                     llama.cpp fork for FPX targets.
                     Default: https://github.com/charlie12345/ROCmFPX.git
  ROCMFPX_LLAMA_BRANCH
                     llama.cpp fork branch for FPX targets. Default: main
  ROCMFPX_LLAMA_REF  llama.cpp fork ref for FPX targets.
                     Default: 014cd28b97d539a0365979d88e9846fad5aa822b
  ROCM_NIGHTLY_TARBALL
                     TheRock tarball for rocm-next targets. Default:
                     therock-dist-linux-gfx1151-7.13.0a20260515.tar.gz
                     Set empty to resolve the latest available tarball.
  ROCMFP4_ROCM_NIGHTLY_TARBALL
                     Deprecated alias for ROCM_NIGHTLY_TARBALL.
  CPU_TARGET         generic, strix-halo, or native. Default: generic
  TAG_VERSION        Also tag stable ROCm as rocm-$ROCM_VERSION. Default: 1
  TAG_NIGHTLY_ALIAS  Also tag rocm-next as rocm7-nightlies. Default: 1
  BUILD_CACHE_REPO   Optional remote registry repo prefix for Buildah cache
  BUILD_LOG_MODE     progress or full. Default: progress
  BUILD_LOG_DIR      Directory for full build logs. Default: .build-logs
  BUILD_LOG_TAIL     Full-log lines to print on failure. Default: 160
  NO_CACHE           Pass --no-cache to the builder. Default: 0
  DRY_RUN            Print build commands without running them. Default: 0
  BUILD_EXTRA_ARGS   Extra build arguments inserted before the context
  ROCWMMA_FATTN      Enable rocWMMA flash-attention kernels for ROCm builds.
                     Default: 0

Examples:
  bin/build.sh
  bin/build.sh rocm
  bin/build.sh rocm=7.2.4
  bin/build.sh rocm-next
  bin/build.sh vulkan
  bin/build.sh vulkan-fp4
  bin/build.sh rocm-fp4
  bin/build.sh rocm-next-fp4
  bin/build.sh vulkan-fpx
  bin/build.sh rocm-fpx
  bin/build.sh rocm-next-fpx
  bin/build.sh --no-cache rocm rocm-next
  bin/build.sh --with-rocwmma rocm rocm-next
  BUILDER=podman bin/build.sh all
EOF
}

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/bin/env-defaults.sh"
load_dotenv_defaults "$PROJECT_ROOT/.env"

BUILDER="${BUILDER:-buildah}"
IMAGE_PREFIX="${IMAGE_PREFIX:-localhost/strix-llama}"
CONTAINERFILE="${CONTAINERFILE:-containers/Containerfile}"
ROCMFP4_CONTAINERFILE="${ROCMFP4_CONTAINERFILE:-containers/Containerfile.rocmfp4}"
ROCMFPX_CONTAINERFILE="${ROCMFPX_CONTAINERFILE:-containers/Containerfile.rocmfpx}"
ROCM_VERSION="${ROCM_VERSION:-7.2.4}"
LLAMA_REPO="${LLAMA_REPO:-https://github.com/ggml-org/llama.cpp.git}"
LLAMA_BRANCH="${LLAMA_BRANCH:-master}"
LLAMA_REF="${LLAMA_REF:-}"
ROCMFP4_LLAMA_REPO="${ROCMFP4_LLAMA_REPO:-https://github.com/charlie12345/rocmfp4-llama.git}"
ROCMFP4_LLAMA_BRANCH="${ROCMFP4_LLAMA_BRANCH:-mtp-rocmfp4-strix}"
ROCMFP4_LLAMA_REF="${ROCMFP4_LLAMA_REF:-4795079b04f5e0ada6e5d2e85b12bac1e27e7873}"
ROCMFPX_LLAMA_REPO="${ROCMFPX_LLAMA_REPO:-https://github.com/charlie12345/ROCmFPX.git}"
ROCMFPX_LLAMA_BRANCH="${ROCMFPX_LLAMA_BRANCH:-main}"
ROCMFPX_LLAMA_REF="${ROCMFPX_LLAMA_REF:-014cd28b97d539a0365979d88e9846fad5aa822b}"
ROCM_NIGHTLY_TARBALL="${ROCM_NIGHTLY_TARBALL-${ROCMFP4_ROCM_NIGHTLY_TARBALL-therock-dist-linux-gfx1151-7.13.0a20260515.tar.gz}}"
CPU_TARGET="${CPU_TARGET:-generic}"
TAG_VERSION="${TAG_VERSION:-1}"
TAG_NIGHTLY_ALIAS="${TAG_NIGHTLY_ALIAS:-1}"
BUILD_LOG_MODE="${BUILD_LOG_MODE:-progress}"
BUILD_LOG_DIR="${BUILD_LOG_DIR:-.build-logs}"
BUILD_LOG_TAIL="${BUILD_LOG_TAIL:-160}"
NO_CACHE="${NO_CACHE:-0}"
DRY_RUN="${DRY_RUN:-0}"
ROCWMMA_FATTN="${ROCWMMA_FATTN:-0}"

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
    --with-rocwmma)
      ROCWMMA_FATTN=1
      ;;
    --no-cache)
      NO_CACHE=1
      ;;
    all)
      TARGETS+=(rocm rocm-next vulkan)
      ;;
    rocm|rocm-next|vulkan|vulkan-fp4|rocm-fp4|rocm-next-fp4|vulkan-fpx|rocm-fpx|rocm-next-fpx)
      TARGETS+=("$target")
      ;;
    rocm=7.2.3|rocm:7.2.3|rocm-7.2.3)
      echo "ROCm 7.2.3 tags were dropped from the next workflow; use rocm or rocm-7.2.4." >&2
      exit 1
      ;;
    rocm=*|rocm:*)
      ROCM_VERSION="${target#rocm?}"
      TARGETS+=(rocm)
      ;;
    rocm-[0-9]*.[0-9]*.[0-9]*)
      ROCM_VERSION="${target#rocm-}"
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

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  TARGETS+=(rocm rocm-next vulkan)
fi

if [[ ! "$ROCM_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ROCM_VERSION must be major.minor.patch, got: $ROCM_VERSION" >&2
  usage
  exit 1
fi

case "$ROCWMMA_FATTN" in
  0|1) ;;
  *)
    echo "ROCWMMA_FATTN must be 0 or 1, got: $ROCWMMA_FATTN" >&2
    usage
    exit 1
    ;;
esac

case "$NO_CACHE" in
  0|1) ;;
  *)
    echo "NO_CACHE must be 0 or 1, got: $NO_CACHE" >&2
    usage
    exit 1
    ;;
esac

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
  local no_cache_args=()
  local cmd=()
  local containerfile="$CONTAINERFILE"
  local llama_repo="$LLAMA_REPO"
  local llama_branch="$LLAMA_BRANCH"
  local llama_ref="$LLAMA_REF"

  if [[ "$build_type" == *-fp4 ]]; then
    containerfile="$ROCMFP4_CONTAINERFILE"
    llama_repo="$ROCMFP4_LLAMA_REPO"
    llama_branch="$ROCMFP4_LLAMA_BRANCH"
    llama_ref="$ROCMFP4_LLAMA_REF"
  elif [[ "$build_type" == *-fpx ]]; then
    containerfile="$ROCMFPX_CONTAINERFILE"
    llama_repo="$ROCMFPX_LLAMA_REPO"
    llama_branch="$ROCMFPX_LLAMA_BRANCH"
    llama_ref="$ROCMFPX_LLAMA_REF"
  fi

  if [[ "$NO_CACHE" == "1" ]]; then
    no_cache_args=(--no-cache)
  fi

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
    vulkan-fp4)
      if [[ "$CPU_TARGET" == "generic" ]]; then
        tag_args=(-t "$IMAGE_PREFIX:vulkan-fp4")
      else
        tag_args=(-t "$IMAGE_PREFIX:vulkan-fp4-$CPU_TARGET")
      fi
      ;;
    rocm-fp4)
      if [[ "$CPU_TARGET" == "generic" ]]; then
        tag_args=(-t "$IMAGE_PREFIX:rocm-fp4")
      else
        tag_args=(-t "$IMAGE_PREFIX:rocm-fp4-$CPU_TARGET")
      fi
      ;;
    rocm-next-fp4)
      if [[ "$CPU_TARGET" == "generic" ]]; then
        tag_args=(-t "$IMAGE_PREFIX:rocm-next-fp4")
      else
        tag_args=(-t "$IMAGE_PREFIX:rocm-next-fp4-$CPU_TARGET")
      fi
      ;;
    rocm-fpx)
      if [[ "$CPU_TARGET" == "generic" ]]; then
        tag_args=(-t "$IMAGE_PREFIX:rocm-fpx")
      else
        tag_args=(-t "$IMAGE_PREFIX:rocm-fpx-$CPU_TARGET")
      fi
      ;;
    vulkan-fpx)
      if [[ "$CPU_TARGET" == "generic" ]]; then
        tag_args=(-t "$IMAGE_PREFIX:vulkan-fpx")
      else
        tag_args=(-t "$IMAGE_PREFIX:vulkan-fpx-$CPU_TARGET")
      fi
      ;;
    rocm-next-fpx)
      if [[ "$CPU_TARGET" == "generic" ]]; then
        tag_args=(-t "$IMAGE_PREFIX:rocm-next-fpx")
      else
        tag_args=(-t "$IMAGE_PREFIX:rocm-next-fpx-$CPU_TARGET")
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
      "${no_cache_args[@]}" \
      --format oci \
      --layers \
      --build-arg "BUILD_TYPE=$build_type" \
      --build-arg "ROCM_VERSION=$ROCM_VERSION" \
      --build-arg "ROCM_REPO_URL=$rocm_repo_url" \
      --build-arg "LLAMA_REPO=$llama_repo" \
      --build-arg "LLAMA_BRANCH=$llama_branch" \
      --build-arg "LLAMA_REF=$llama_ref" \
      --build-arg "ROCM_NIGHTLY_TARBALL=$ROCM_NIGHTLY_TARBALL" \
      --build-arg "CPU_TARGET=$CPU_TARGET" \
      --build-arg "ROCWMMA_FATTN=$ROCWMMA_FATTN" \
      "${cache_args[@]}" \
      "${tag_args[@]}" \
      -f "$containerfile" \
      "${BUILD_EXTRA[@]}" \
      .)
  else
    cmd=("$BUILDER" build \
      --pull \
      "${no_cache_args[@]}" \
      --format oci \
      --layers \
      --build-arg "BUILD_TYPE=$build_type" \
      --build-arg "ROCM_VERSION=$ROCM_VERSION" \
      --build-arg "ROCM_REPO_URL=$rocm_repo_url" \
      --build-arg "LLAMA_REPO=$llama_repo" \
      --build-arg "LLAMA_BRANCH=$llama_branch" \
      --build-arg "LLAMA_REF=$llama_ref" \
      --build-arg "ROCM_NIGHTLY_TARBALL=$ROCM_NIGHTLY_TARBALL" \
      --build-arg "CPU_TARGET=$CPU_TARGET" \
      --build-arg "ROCWMMA_FATTN=$ROCWMMA_FATTN" \
      "${cache_args[@]}" \
      "${tag_args[@]}" \
      -f "$containerfile" \
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
      /^ROCm nightly tarball:/ { print; fflush(); next }
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
