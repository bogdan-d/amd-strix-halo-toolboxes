#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bin/podman-llama.sh <backend> <command> [args...]

Backends:
  rocm       Stable ROCm image
  rocm-next  ROCm nightly image
  vulkan     Vulkan RADV image

Commands:
  shell                 Open a shell in a running selected image, or start one
  list-devices          Run llama-cli --list-devices
  server <model> [...]  Run llama-server with Strix Halo defaults
  mtp-server <model> [draft-n] [...]
                        Run llama-server with draft MTP enabled
  load-test <model> [...] Start llama-server, wait for model load, then stop
  cli <model> [...]     Run llama-cli with Strix Halo defaults
  bench <model> [...]   Run llama-bench with Strix Halo defaults
  run <cmd> [...]       Run an arbitrary command in the selected image
  pull                  Pull the selected image

Environment:
  .env                  Root project .env is loaded automatically if present
  IMAGE_PREFIX          Image repository prefix. Default: localhost/amd-strix-halo-toolboxes
  MODELS_DIR            Host model directory to mount. Default: ~/models
  CONTAINER_MODELS_DIR  Container model directory. Default: /root/models
  LLAMA_PORT            Host/container server port. Default: 8080
  LLAMA_CONTEXT         Default server/CLI context and bench depth. Default: 131072
  LLAMA_BATCH           Default logical batch size. Default: 2048
  LLAMA_UBATCH          Default physical batch size. Vulkan: 512, ROCm: 2048
  LLAMA_NGL             GPU layers to offload. Default: 999
  LLAMA_BENCH_NGL       GPU layers for llama-bench. Default: 99
  LLAMA_PREDICT         Default CLI prediction tokens. Default: -1
  LLAMA_LOAD_TEST_TIMEOUT
                        Seconds to wait for load-test. Default: 120
  HF_CACHE_DIR          Host Hugging Face cache directory. Default: ~/.cache/huggingface
  HF_HOME               Container Hugging Face cache directory. Default: /root/.cache/huggingface
  PODMAN_CONTAINER      Existing container name/id to use for shell
  PODMAN_NAME           Container name for new shell/server containers
  PODMAN_NAME_PREFIX    Container name prefix. Default: amd-strix-halo-llama
  PODMAN_EXTRA_ARGS     Extra arguments inserted before the image name

Examples:
  bin/podman-llama.sh rocm list-devices
  bin/podman-llama.sh vulkan server ~/models/model.gguf
  bin/podman-llama.sh rocm-next cli ~/models/model.gguf -p "Hello"
EOF
}

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$PROJECT_ROOT/.env"
ENV_NAMES=()

load_env_file() {
  local env_file="$1"
  local line name

  [[ -f "$env_file" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)= ]] || continue
    name="${BASH_REMATCH[2]}"
    ENV_NAMES+=("$name")
  done < "$env_file"

  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a
}

load_env_file "$ENV_FILE"

if [[ $# -lt 2 ]]; then
  usage
  exit 1
fi

BACKEND="$1"
ACTION="$2"
shift 2
IMAGE_PREFIX="${IMAGE_PREFIX:-localhost/amd-strix-halo-toolboxes}"

case "$BACKEND" in
  vulkan|vulkan-radv|vulkan_radv)
    BACKEND_NAME="vulkan"
    IMAGE="$IMAGE_PREFIX:vulkan"
    DEVICE_ARGS=(--device /dev/dri)
    DEFAULT_UBATCH=512
    ;;
  rocm|rocm-7.2.3|rocm-7_2_3)
    BACKEND_NAME="rocm"
    IMAGE="$IMAGE_PREFIX:rocm"
    DEVICE_ARGS=(--device /dev/dri --device /dev/kfd)
    DEFAULT_UBATCH=2048
    ;;
  rocm-next|rocm7-nightlies)
    BACKEND_NAME="rocm-next"
    IMAGE="$IMAGE_PREFIX:rocm-next"
    DEVICE_ARGS=(--device /dev/dri --device /dev/kfd)
    DEFAULT_UBATCH=2048
    ;;
  *)
    echo "Unknown backend: $BACKEND" >&2
    usage
    exit 1
    ;;
esac

MODELS_DIR="${MODELS_DIR:-$HOME/models}"
CONTAINER_MODELS_DIR="${CONTAINER_MODELS_DIR:-/root/models}"
LLAMA_PORT="${LLAMA_PORT:-8080}"
LLAMA_CONTEXT="${LLAMA_CONTEXT:-131072}"
LLAMA_BATCH="${LLAMA_BATCH:-2048}"
LLAMA_UBATCH="${LLAMA_UBATCH:-$DEFAULT_UBATCH}"
LLAMA_NGL="${LLAMA_NGL:-999}"
LLAMA_BENCH_NGL="${LLAMA_BENCH_NGL:-99}"
LLAMA_PREDICT="${LLAMA_PREDICT:--1}"
LLAMA_LOAD_TEST_TIMEOUT="${LLAMA_LOAD_TEST_TIMEOUT:-120}"
HF_CACHE_DIR="${HF_CACHE_DIR:-$HOME/.cache/huggingface}"
HF_HOME="${HF_HOME:-/root/.cache/huggingface}"
PODMAN_NAME_PREFIX="${PODMAN_NAME_PREFIX:-amd-strix-halo-llama}"
DEFAULT_CONTAINER_NAME="$PODMAN_NAME_PREFIX-$BACKEND_NAME-$ACTION"

if [[ "$ACTION" == "pull" ]]; then
  exec podman pull "$IMAGE"
fi

RUN_TTY=()
if [[ -t 0 && -t 1 ]]; then
  RUN_TTY=(-it)
else
  RUN_TTY=(-i)
fi

EXTRA_ARGS=()
if [[ -n "${PODMAN_EXTRA_ARGS:-}" ]]; then
  # Intentional shell splitting: this variable is for advanced podman flags.
  # shellcheck disable=SC2206
  EXTRA_ARGS=(${PODMAN_EXTRA_ARGS})
fi

ENV_ARGS=()
for name in "${ENV_NAMES[@]}"; do
  ENV_ARGS+=(--env "$name")
done

container_model_path() {
  local model="$1"
  local model_abs
  model_abs="$(realpath -m "$model")"
  local models_abs
  models_abs="$(realpath -m "$MODELS_DIR")"

  if [[ ! -d "$MODELS_DIR" ]]; then
    echo "MODELS_DIR does not exist: $MODELS_DIR" >&2
    exit 1
  fi

  if [[ ! -f "$model_abs" ]]; then
    echo "Model file does not exist: $model_abs" >&2
    exit 1
  fi

  case "$model_abs" in
    "$models_abs"/*)
      printf '%s/%s\n' "$CONTAINER_MODELS_DIR" "${model_abs#"$models_abs"/}"
      ;;
    *)
      echo "Model must live under MODELS_DIR: $MODELS_DIR" >&2
      echo "Set MODELS_DIR=/path/to/models or move the model under that directory." >&2
      exit 1
      ;;
  esac
}

PODMAN_RUN_ARGS=()
VOLUME_ARGS=()
if [[ -d "$MODELS_DIR" ]]; then
  VOLUME_ARGS=(--volume "$MODELS_DIR:$CONTAINER_MODELS_DIR" --workdir "$CONTAINER_MODELS_DIR")
fi
mkdir -p "$HF_CACHE_DIR"
CACHE_ARGS=(--volume "$HF_CACHE_DIR:$HF_HOME" --env "HF_HOME=$HF_HOME")

container_name_args() {
  printf '%s\n' --replace --name "${PODMAN_NAME:-$DEFAULT_CONTAINER_NAME}"
}

running_container_id() {
  local ids=()

  if [[ -n "${PODMAN_CONTAINER:-}" ]]; then
    printf '%s\n' "$PODMAN_CONTAINER"
    return 0
  fi

  mapfile -t ids < <(podman ps --filter "ancestor=$IMAGE" --format '{{.ID}}')

  case "${#ids[@]}" in
    0)
      return 1
      ;;
    1)
      printf '%s\n' "${ids[0]}"
      ;;
    *)
      echo "Multiple running containers use image $IMAGE." >&2
      echo "Set PODMAN_CONTAINER=<name-or-id> in .env or the environment." >&2
      podman ps --filter "ancestor=$IMAGE" --format '  {{.ID}} {{.Names}} {{.Command}}' >&2
      exit 1
      ;;
  esac
}

base_run() {
  podman run --rm "${RUN_TTY[@]}" \
    --security-opt seccomp=unconfined \
    --security-opt label=disable \
    --group-add keep-groups \
    --ipc=host \
    "${DEVICE_ARGS[@]}" \
    "${VOLUME_ARGS[@]}" \
    "${CACHE_ARGS[@]}" \
    "${ENV_ARGS[@]}" \
    "${EXTRA_ARGS[@]}" \
    "${PODMAN_RUN_ARGS[@]}" \
    "$IMAGE" "$@"
}

base_run_detached() {
  podman run --rm --detach \
    --security-opt seccomp=unconfined \
    --security-opt label=disable \
    --group-add keep-groups \
    --ipc=host \
    "${DEVICE_ARGS[@]}" \
    "${VOLUME_ARGS[@]}" \
    "${CACHE_ARGS[@]}" \
    "${ENV_ARGS[@]}" \
    "${EXTRA_ARGS[@]}" \
    "${PODMAN_RUN_ARGS[@]}" \
    "$IMAGE" "$@"
}

require_model() {
  if [[ $# -lt 1 ]]; then
    echo "Missing model path." >&2
    usage
    exit 1
  fi
}

case "$ACTION" in
  shell)
    if CONTAINER_ID="$(running_container_id)"; then
      exec podman exec "${RUN_TTY[@]}" "$CONTAINER_ID" /bin/bash
    fi
    mapfile -t PODMAN_RUN_ARGS < <(container_name_args)
    base_run /bin/bash
    ;;
  list-devices)
    base_run llama-cli --list-devices
    ;;
  server)
    require_model "$@"
    MODEL="$(container_model_path "$1")"
    shift
    mapfile -t PODMAN_RUN_ARGS < <(container_name_args)
    PODMAN_RUN_ARGS+=(-p "$LLAMA_PORT:$LLAMA_PORT")
    base_run llama-server \
      -m "$MODEL" \
      --host 0.0.0.0 \
      --port "$LLAMA_PORT" \
      -c "$LLAMA_CONTEXT" \
      -b "$LLAMA_BATCH" \
      -ub "$LLAMA_UBATCH" \
      -ngl "$LLAMA_NGL" \
      -fa 1 \
      --no-mmap \
      "$@"
    ;;
  mtp-server)
    require_model "$@"
    MODEL="$(container_model_path "$1")"
    shift
    DRAFT_N="3"
    if [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]]; then
      DRAFT_N="$1"
      shift
    fi
    mapfile -t PODMAN_RUN_ARGS < <(container_name_args)
    PODMAN_RUN_ARGS+=(-p "$LLAMA_PORT:$LLAMA_PORT")
    base_run llama-server \
      -m "$MODEL" \
      --host 0.0.0.0 \
      --port "$LLAMA_PORT" \
      -c "$LLAMA_CONTEXT" \
      -b "$LLAMA_BATCH" \
      -ub "$LLAMA_UBATCH" \
      -ngl "$LLAMA_NGL" \
      -fa 1 \
      --no-mmap \
      --spec-type draft-mtp \
      --spec-draft-n-max "$DRAFT_N" \
      --spec-type ngram-map-k4v \
      --spec-ngram-map-k4v-size-n 16 \
      --spec-ngram-map-k4v-size-m 24 \
      --spec-ngram-map-k4v-min-hits 2 \
      -np 1 \
      "$@"
    ;;
  load-test)
    require_model "$@"
    MODEL="$(container_model_path "$1")"
    shift
    mapfile -t PODMAN_RUN_ARGS < <(container_name_args)
    CONTAINER_ID="$(base_run_detached llama-server \
      -m "$MODEL" \
      --host 127.0.0.1 \
      --port "$LLAMA_PORT" \
      -c "$LLAMA_CONTEXT" \
      -b "$LLAMA_BATCH" \
      -ub "$LLAMA_UBATCH" \
      -ngl "$LLAMA_NGL" \
      -fa 1 \
      --no-mmap \
      --no-warmup \
      --cache-ram 0 \
      --no-ui \
      "$@")"
    cleanup_load_test() {
      podman stop "$CONTAINER_ID" >/dev/null 2>&1 || true
    }
    trap cleanup_load_test EXIT
    deadline=$((SECONDS + LLAMA_LOAD_TEST_TIMEOUT))
    while (( SECONDS < deadline )); do
      if ! podman container exists "$CONTAINER_ID"; then
        echo "load-test container exited before model load" >&2
        exit 1
      fi
      if [[ "$(podman inspect -f '{{.State.Running}}' "$CONTAINER_ID" 2>/dev/null || true)" != "true" ]]; then
        podman logs "$CONTAINER_ID" >&2 || true
        echo "load-test container stopped before model load" >&2
        exit 1
      fi
      if podman logs "$CONTAINER_ID" 2>&1 | grep -q 'model loaded'; then
        podman logs "$CONTAINER_ID" 2>&1 | tail -n 40
        echo "load-test passed: model loaded"
        exit 0
      fi
      sleep 1
    done
    podman logs "$CONTAINER_ID" >&2 || true
    echo "load-test timed out after ${LLAMA_LOAD_TEST_TIMEOUT}s" >&2
    exit 124
    ;;
  cli)
    require_model "$@"
    MODEL="$(container_model_path "$1")"
    shift
    base_run llama-cli \
      -m "$MODEL" \
      -c "$LLAMA_CONTEXT" \
      -b "$LLAMA_BATCH" \
      -ub "$LLAMA_UBATCH" \
      -ngl "$LLAMA_NGL" \
      -fa 1 \
      --no-mmap \
      -n "$LLAMA_PREDICT" \
      "$@"
    ;;
  bench)
    require_model "$@"
    MODEL="$(container_model_path "$1")"
    shift
    base_run llama-bench \
      -m "$MODEL" \
      -ngl "$LLAMA_BENCH_NGL" \
      -fa 1 \
      -mmp 0 \
      -p "$LLAMA_BATCH" \
      -n 32 \
      -d "$LLAMA_CONTEXT" \
      -ub "$LLAMA_UBATCH" \
      "$@"
    ;;
  run)
    base_run "$@"
    ;;
  *)
    echo "Unknown command: $ACTION" >&2
    usage
    exit 1
    ;;
esac
