#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bin/run.sh [options] <backend> <command> [args...]

Options:
  --with-non-reasoning  Add generated Qwen/Qwen-derived :non-reasoning presets
  --with-vision         Add generated :vision presets for models with mmproj GGUF
  --with-configs        Refresh coding-tool configs from the generated preset

Backends:
  rocm       Stable ROCm image resolved from CPU_TARGET
  rocm-next  ROCm nightly image resolved from CPU_TARGET
  rocmfp4-llama
             Stable ROCm image with the custom ROCmFP4 llama.cpp fork
  rocmfp4-llama-next
             ROCm nightly image with the custom ROCmFP4 llama.cpp fork
  vulkan     Vulkan RADV image resolved from CPU_TARGET
  Explicit build tags from bin/build.sh also work, for example:
             rocm-7.2.4, rocm-strix-halo, rocm-next-strix-halo,
             rocmfp4-llama-strix-halo, rocmfp4-llama-next-strix-halo,
             rocm7-nightlies-native, vulkan-native

Commands:
  shell                 Open a shell in a running selected image, or start one
  list-devices          Run llama-cli --list-devices
  models                List generated model IDs, or IDs from LLAMA_MODELS_PRESET
  server [model] [...]  Run llama-server with generated preset, or one direct model
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
  CPU_TARGET            Image CPU target variant. Default: generic
  ROCM_VERSION          Stable ROCm version for versioned rocm aliases. Default: 7.2.4
  MODELS_DIR            Host model directory to mount. Default: ~/models
  CONTAINER_MODELS_DIR  Container model directory. Default: /root/models
  LLAMA_MODELS_PRESET   Explicit host models preset file. Default: generated
                        from ./models-template.ini and MODELS_DIR discovery
  LLAMA_MODELS_TEMPLATE Host models template file. Default: ./models-template.ini
  LLAMA_MODELS_MAX      Maximum models loaded by preset server. Default: 1
  LLAMA_PORT            Host/container server port. Default: 8080
  LLAMA_CONTEXT         Default server/CLI context and bench depth. Default: 131072
  LLAMA_BATCH           Default logical batch size. Vulkan: 2048, ROCm: 4096,
                        ROCmFP4: 512
  LLAMA_UBATCH          Default physical batch size. Vulkan: 512, ROCm: 2048,
                        ROCmFP4: 512
  GGML_HIP_MAX_BATCH_SIZE
                        ROCm HIP batch cap. Default for ROCm: 2048
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
  bin/run.sh rocm list-devices
  CPU_TARGET=strix-halo bin/run.sh rocm list-devices
  bin/run.sh rocm models
  bin/run.sh vulkan server
  bin/run.sh rocm-7.2.4 server
  bin/run.sh vulkan server ~/models/model.gguf
  bin/run.sh rocm-next cli ~/models/model.gguf -p "Hello"
EOF
}

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/bin/env-defaults.sh"
ENV_FILE="$PROJECT_ROOT/.env"
ENV_NAMES=()
declare -A ENV_NAME_SEEN=()

collect_env_names() {
  local env_file="$1"
  local line name

  [[ -f "$env_file" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)= ]] || continue
    name="${BASH_REMATCH[2]}"
    [[ -n "${ENV_NAME_SEEN[$name]+x}" ]] && continue
    ENV_NAME_SEEN["$name"]=1
    ENV_NAMES+=("$name")
  done < "$env_file"
}

collect_env_names "$ENV_FILE"
load_dotenv_defaults "$ENV_FILE"

GENERATE_MODELS_PRESET_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-non-reasoning|--with-vision|--with-configs)
      GENERATE_MODELS_PRESET_ARGS+=("$1")
      shift
      ;;
    --)
      shift
      break
      ;;
    --*)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

if [[ $# -lt 2 ]]; then
  usage
  exit 1
fi

BACKEND="$1"
ACTION="$2"
shift 2
IMAGE_PREFIX="${IMAGE_PREFIX:-localhost/amd-strix-halo-toolboxes}"
CPU_TARGET="${CPU_TARGET:-generic}"
ROCM_VERSION="${ROCM_VERSION:-7.2.4}"

cpu_target_suffix() {
  if [[ "$CPU_TARGET" == "generic" ]]; then
    return 0
  fi

  printf -- '-%s' "$CPU_TARGET"
}

stable_rocm_tag() {
  printf 'rocm%s' "$(cpu_target_suffix)"
}

stable_rocm_version_tag() {
  if [[ "$CPU_TARGET" == "generic" ]]; then
    printf 'rocm-%s' "$ROCM_VERSION"
    return 0
  fi

  printf 'rocm-%s-%s' "$ROCM_VERSION" "$CPU_TARGET"
}

rocm_next_tag() {
  printf 'rocm-next%s' "$(cpu_target_suffix)"
}

rocm_next_alias_tag() {
  printf 'rocm7-nightlies%s' "$(cpu_target_suffix)"
}

rocmfp4_llama_tag() {
  printf 'rocmfp4-llama%s' "$(cpu_target_suffix)"
}

rocmfp4_llama_next_tag() {
  printf 'rocmfp4-llama-next%s' "$(cpu_target_suffix)"
}

vulkan_tag() {
  printf 'vulkan%s' "$(cpu_target_suffix)"
}

BACKEND_INPUT="${BACKEND//_/-}"

case "$BACKEND_INPUT" in
  vulkan|vulkan-radv)
    BACKEND_FAMILY="vulkan"
    IMAGE_TAG="$(vulkan_tag)"
    DEVICE_ARGS=(--device /dev/dri)
    DEFAULT_BATCH=2048
    DEFAULT_UBATCH=512
    ;;
  vulkan-radv-*)
    BACKEND_FAMILY="vulkan"
    IMAGE_TAG="vulkan-${BACKEND_INPUT#vulkan-radv-}"
    DEVICE_ARGS=(--device /dev/dri)
    DEFAULT_BATCH=2048
    DEFAULT_UBATCH=512
    ;;
  vulkan-*)
    BACKEND_FAMILY="vulkan"
    IMAGE_TAG="$BACKEND_INPUT"
    DEVICE_ARGS=(--device /dev/dri)
    DEFAULT_BATCH=2048
    DEFAULT_UBATCH=512
    ;;
  rocm-next)
    BACKEND_FAMILY="rocm-next"
    IMAGE_TAG="$(rocm_next_tag)"
    DEVICE_ARGS=(--device /dev/dri --device /dev/kfd)
    DEFAULT_BATCH=4096
    DEFAULT_UBATCH=2048
    ;;
  rocm7-nightlies)
    BACKEND_FAMILY="rocm-next"
    IMAGE_TAG="$(rocm_next_alias_tag)"
    DEVICE_ARGS=(--device /dev/dri --device /dev/kfd)
    DEFAULT_BATCH=4096
    DEFAULT_UBATCH=2048
    ;;
  rocm-next-*|rocm7-nightlies-*)
    BACKEND_FAMILY="rocm-next"
    IMAGE_TAG="$BACKEND_INPUT"
    DEVICE_ARGS=(--device /dev/dri --device /dev/kfd)
    DEFAULT_BATCH=4096
    DEFAULT_UBATCH=2048
    ;;
  rocmfp4-llama)
    BACKEND_FAMILY="rocmfp4-llama"
    IMAGE_TAG="$(rocmfp4_llama_tag)"
    DEVICE_ARGS=(--device /dev/dri --device /dev/kfd)
    DEFAULT_BATCH=512
    DEFAULT_UBATCH=512
    ;;
  rocmfp4-llama-next)
    BACKEND_FAMILY="rocmfp4-llama-next"
    IMAGE_TAG="$(rocmfp4_llama_next_tag)"
    DEVICE_ARGS=(--device /dev/dri --device /dev/kfd)
    DEFAULT_BATCH=512
    DEFAULT_UBATCH=512
    ;;
  rocmfp4-llama-next-*)
    BACKEND_FAMILY="rocmfp4-llama-next"
    IMAGE_TAG="$BACKEND_INPUT"
    DEVICE_ARGS=(--device /dev/dri --device /dev/kfd)
    DEFAULT_BATCH=512
    DEFAULT_UBATCH=512
    ;;
  rocmfp4-llama-*)
    BACKEND_FAMILY="rocmfp4-llama"
    IMAGE_TAG="$BACKEND_INPUT"
    DEVICE_ARGS=(--device /dev/dri --device /dev/kfd)
    DEFAULT_BATCH=512
    DEFAULT_UBATCH=512
    ;;
  rocm)
    BACKEND_FAMILY="rocm"
    IMAGE_TAG="$(stable_rocm_tag)"
    DEVICE_ARGS=(--device /dev/dri --device /dev/kfd)
    DEFAULT_BATCH=4096
    DEFAULT_UBATCH=2048
    ;;
  "rocm-$ROCM_VERSION")
    BACKEND_FAMILY="rocm"
    IMAGE_TAG="$(stable_rocm_version_tag)"
    DEVICE_ARGS=(--device /dev/dri --device /dev/kfd)
    DEFAULT_BATCH=4096
    DEFAULT_UBATCH=2048
    ;;
  rocm-[0-9]*.[0-9]*.[0-9]*|rocm-*)
    BACKEND_FAMILY="rocm"
    IMAGE_TAG="$BACKEND_INPUT"
    DEVICE_ARGS=(--device /dev/dri --device /dev/kfd)
    DEFAULT_BATCH=4096
    DEFAULT_UBATCH=2048
    ;;
  *)
    echo "Unknown backend: $BACKEND" >&2
    usage
    exit 1
    ;;
esac

IMAGE="$IMAGE_PREFIX:$IMAGE_TAG"

if [[ "$BACKEND_FAMILY" == rocmfp4-llama* ]]; then
  GENERATE_MODELS_PRESET_ARGS+=(--rocmfp4-only)
  HSA_OVERRIDE_GFX_VERSION="${HSA_OVERRIDE_GFX_VERSION:-11.5.1}"
  GGML_HIP_ENABLE_UNIFIED_MEMORY="${GGML_HIP_ENABLE_UNIFIED_MEMORY:-1}"
fi

MODELS_DIR="${MODELS_DIR:-$HOME/models}"
CONTAINER_MODELS_DIR="${CONTAINER_MODELS_DIR:-/root/models}"
if [[ -n "${LLAMA_MODELS_PRESET:-}" ]]; then
  LLAMA_MODELS_PRESET_EXPLICIT=1
else
  LLAMA_MODELS_PRESET_EXPLICIT=0
  LLAMA_MODELS_PRESET=""
fi
LLAMA_MODELS_TEMPLATE="${LLAMA_MODELS_TEMPLATE:-$PROJECT_ROOT/models-template.ini}"
LLAMA_MODELS_MAX="${LLAMA_MODELS_MAX:-1}"
LLAMA_PORT="${LLAMA_PORT:-8080}"
LLAMA_CONTEXT="${LLAMA_CONTEXT:-131072}"
LLAMA_BATCH="${LLAMA_BATCH:-$DEFAULT_BATCH}"
LLAMA_UBATCH="${LLAMA_UBATCH:-$DEFAULT_UBATCH}"
LLAMA_NGL="${LLAMA_NGL:-999}"
LLAMA_BENCH_NGL="${LLAMA_BENCH_NGL:-99}"
LLAMA_PREDICT="${LLAMA_PREDICT:--1}"
LLAMA_LOAD_TEST_TIMEOUT="${LLAMA_LOAD_TEST_TIMEOUT:-120}"
HF_CACHE_DIR="${HF_CACHE_DIR:-$HOME/.cache/huggingface}"
HF_HOME="${HF_HOME:-/root/.cache/huggingface}"
PODMAN_NAME_PREFIX="${PODMAN_NAME_PREFIX:-amd-strix-halo-llama}"
DEFAULT_CONTAINER_NAME="$PODMAN_NAME_PREFIX-$IMAGE_TAG-$ACTION"

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
  case "$name" in
    HF_HOME)
      continue
      ;;
    HSA_OVERRIDE_GFX_VERSION|GGML_HIP_ENABLE_UNIFIED_MEMORY)
      if [[ "$BACKEND_FAMILY" == rocmfp4-llama* ]]; then
        continue
      fi
      ;;
    GGML_HIP_MAX_BATCH_SIZE)
      if [[ "$BACKEND_FAMILY" == rocm* ]]; then
        continue
      fi
      ;;
  esac
  ENV_ARGS+=(--env "$name")
done
if [[ "$BACKEND_FAMILY" == rocm* ]]; then
  GGML_HIP_MAX_BATCH_SIZE="${GGML_HIP_MAX_BATCH_SIZE:-2048}"
  ENV_ARGS+=(--env "GGML_HIP_MAX_BATCH_SIZE=$GGML_HIP_MAX_BATCH_SIZE")
fi
if [[ "$BACKEND_FAMILY" == rocmfp4-llama* ]]; then
  ENV_ARGS+=(
    --env "HSA_OVERRIDE_GFX_VERSION=$HSA_OVERRIDE_GFX_VERSION"
    --env "GGML_HIP_ENABLE_UNIFIED_MEMORY=$GGML_HIP_ENABLE_UNIFIED_MEMORY"
  )
fi

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

container_models_preset_path() {
  local preset="$1"
  local preset_abs
  preset_abs="$(realpath -m "$preset")"
  local models_abs
  models_abs="$(realpath -m "$MODELS_DIR")"

  if [[ ! -d "$MODELS_DIR" ]]; then
    echo "MODELS_DIR does not exist: $MODELS_DIR" >&2
    exit 1
  fi

  if [[ ! -f "$preset_abs" ]]; then
    echo "Models preset does not exist: $preset_abs" >&2
    echo "Set LLAMA_MODELS_PRESET=/path/to/models.ini or leave it unset for generated discovery." >&2
    exit 1
  fi

  case "$preset_abs" in
    "$models_abs"/*)
      printf '%s/%s\n' "$CONTAINER_MODELS_DIR" "${preset_abs#"$models_abs"/}"
      ;;
    *)
      echo "Models preset must live under MODELS_DIR: $MODELS_DIR" >&2
      echo "Set MODELS_DIR=/path/to/models or move the preset under that directory." >&2
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

selected_container() {
  local i

  if [[ -n "${PODMAN_CONTAINER:-}" ]]; then
    printf '%s\n' "$PODMAN_CONTAINER"
    return 0
  fi

  for (( i = 0; i < ${#PODMAN_RUN_ARGS[@]}; i++ )); do
    if [[ "${PODMAN_RUN_ARGS[i]}" == "--name" ]] && (( i + 1 < ${#PODMAN_RUN_ARGS[@]} )); then
      printf '%s\n' "${PODMAN_RUN_ARGS[i + 1]}"
      return 0
    fi
  done

  printf '%s\n' '(ephemeral)'
}

log_selection() {
  local container_name="$1"
  printf 'run.sh: selected image=%s container=%s action=%s\n' "$IMAGE" "$container_name" "$ACTION" >&2
}

log_command() {
  printf 'run.sh: command:' >&2
  printf ' %q' "$@" >&2
  printf '\n' >&2
}

run_logged() {
  local container_name="$1"
  shift
  log_selection "$container_name"
  log_command "$@"
  "$@"
}

exec_logged() {
  local container_name="$1"
  shift
  log_selection "$container_name"
  log_command "$@"
  exec "$@"
}

if [[ "$ACTION" == "pull" ]]; then
  exec_logged '(image-only)' podman pull "$IMAGE"
fi

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
  local cmd=(podman run --rm "${RUN_TTY[@]}" \
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
    "$IMAGE" "$@")
  run_logged "$(selected_container)" "${cmd[@]}"
}

base_run_detached() {
  local cmd=(podman run --rm --detach \
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
    "$IMAGE" "$@")
  run_logged "$(selected_container)" "${cmd[@]}"
}

require_model() {
  if [[ $# -lt 1 ]]; then
    echo "Missing model path." >&2
    usage
    exit 1
  fi
}

GENERATED_MODELS_PRESET=""
GENERATED_MODELS_PRESET_CONTAINER="/tmp/llama-models.ini"

cleanup_generated_models_preset() {
  if [[ -n "$GENERATED_MODELS_PRESET" ]]; then
    rm -f "$GENERATED_MODELS_PRESET"
  fi
}

generate_models_preset_file() {
  local output

  output="$(mktemp "${TMPDIR:-/tmp}/llama-models.XXXXXX.ini")"
  "$PROJECT_ROOT/bin/generate-models-preset.sh" \
    "${GENERATE_MODELS_PRESET_ARGS[@]}" \
    "$MODELS_DIR" \
    "$CONTAINER_MODELS_DIR" \
    "$LLAMA_MODELS_TEMPLATE" \
    "$output"

  GENERATED_MODELS_PRESET="$output"
  trap cleanup_generated_models_preset EXIT
  VOLUME_ARGS+=(--volume "$GENERATED_MODELS_PRESET:$GENERATED_MODELS_PRESET_CONTAINER:ro")
  echo "run.sh: generated models preset=$GENERATED_MODELS_PRESET from template=$LLAMA_MODELS_TEMPLATE" >&2
}

list_models_preset() {
  local preset="$1"
  local preset_abs line section
  preset_abs="$(realpath -m "$preset")"

  if [[ ! -f "$preset_abs" ]]; then
    echo "Models preset does not exist: $preset_abs" >&2
    echo "Set LLAMA_MODELS_PRESET=/path/to/models.ini or use generated discovery from $LLAMA_MODELS_TEMPLATE." >&2
    exit 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*\[([^]]+)\][[:space:]]*$ ]] || continue
    section="${BASH_REMATCH[1]}"
    [[ "$section" == "*" ]] && continue
    printf '%s\n' "$section"
  done < "$preset_abs"
}

list_generated_models_preset() {
  "$PROJECT_ROOT/bin/generate-models-preset.sh" \
    "${GENERATE_MODELS_PRESET_ARGS[@]}" \
    "$MODELS_DIR" \
    "$CONTAINER_MODELS_DIR" \
    "$LLAMA_MODELS_TEMPLATE" \
    | while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*\[([^]]+)\][[:space:]]*$ ]] || continue
        section="${BASH_REMATCH[1]}"
        [[ "$section" == "*" ]] && continue
        printf '%s\n' "$section"
      done
}

case "$ACTION" in
  shell)
    if CONTAINER_ID="$(running_container_id)"; then
      exec_logged "$CONTAINER_ID" podman exec "${RUN_TTY[@]}" "$CONTAINER_ID" /bin/bash
    fi
    mapfile -t PODMAN_RUN_ARGS < <(container_name_args)
    base_run /bin/bash
    ;;
  list-devices)
    base_run llama-cli --list-devices
    ;;
  models)
    if (( LLAMA_MODELS_PRESET_EXPLICIT )); then
      list_models_preset "$LLAMA_MODELS_PRESET"
    else
      list_generated_models_preset
    fi
    ;;
  server)
    mapfile -t PODMAN_RUN_ARGS < <(container_name_args)
    PODMAN_RUN_ARGS+=(-p "$LLAMA_PORT:$LLAMA_PORT")

    if [[ $# -eq 0 || "$1" == -* ]]; then
      if (( LLAMA_MODELS_PRESET_EXPLICIT )); then
        MODELS_PRESET="$(container_models_preset_path "$LLAMA_MODELS_PRESET")"
      else
        generate_models_preset_file
        MODELS_PRESET="$GENERATED_MODELS_PRESET_CONTAINER"
      fi
      base_run llama-server \
        --models-preset "$MODELS_PRESET" \
        --models-max "$LLAMA_MODELS_MAX" \
        --host 0.0.0.0 \
        --port "$LLAMA_PORT" \
        --batch-size "$LLAMA_BATCH" \
        --ubatch-size "$LLAMA_UBATCH" \
        "$@"
      exit 0
    fi

    MODEL="$(container_model_path "$1")"
    shift
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
    LOAD_TEST_ARGS=()
    if [[ "$BACKEND_FAMILY" != rocmfp4-llama* ]]; then
      LOAD_TEST_ARGS+=(--no-ui)
    fi
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
      "${LOAD_TEST_ARGS[@]}" \
      "$@")"
    # shellcheck disable=SC2329
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
