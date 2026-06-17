#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bin/generate-models-preset.sh [--with-non-reasoning] [--with-vision] [--with-configs] [--rocmfp4-only] [--rocmfp4-device DEVICE] <models-dir> <container-models-dir> <template> [output]

Generate a llama.cpp --models-preset INI by copying shared defaults from the
tracked template and appending discovered GGUF model sections.

Options:
  --with-non-reasoning  Add Qwen/Qwen-derived :non-reasoning variants.
  --with-vision         Add :vision variants for models with one paired mmproj GGUF.
  --with-configs        Refresh coding-tool configs from the generated preset.
  --rocmfp4-only        Generate only ROCmFP4 presets for the custom fork image.
  --rocmfp4-device      Device name for ROCmFP4 presets. Default: ROCm0.
  --fp4-only            Alias for --rocmfp4-only.
EOF
}

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WITH_NON_REASONING=0
WITH_VISION=0
WITH_CONFIGS=0
ROCMFP4_ONLY=0
ROCMFP4_DEVICE=ROCm0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-non-reasoning)
      WITH_NON_REASONING=1
      shift
      ;;
    --with-vision)
      WITH_VISION=1
      shift
      ;;
    --with-configs)
      WITH_CONFIGS=1
      shift
      ;;
    --rocmfp4-only|--fp4-only)
      ROCMFP4_ONLY=1
      shift
      ;;
    --rocmfp4-device)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        echo "Missing value for --rocmfp4-device" >&2
        usage >&2
        exit 1
      fi
      ROCMFP4_DEVICE="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    --*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

if [[ $# -lt 3 || $# -gt 4 ]]; then
  usage >&2
  exit 1
fi

MODELS_DIR="$1"
CONTAINER_MODELS_DIR="$2"
TEMPLATE="$3"
OUTPUT="${4:-/dev/stdout}"

if [[ ! -d "$MODELS_DIR" ]]; then
  echo "MODELS_DIR does not exist: $MODELS_DIR" >&2
  exit 1
fi

if [[ ! -f "$TEMPLATE" ]]; then
  echo "Models template does not exist: $TEMPLATE" >&2
  exit 1
fi

trim_trailing_slash() {
  local value="$1"
  while [[ "$value" != "/" && "$value" == */ ]]; do
    value="${value%/}"
  done
  printf '%s\n' "$value"
}

filename_stem() {
  local name="$1"
  name="${name##*/}"
  printf '%s\n' "${name%.gguf}"
}

infer_quant() {
  local rel="$1"
  local stem
  stem="$(filename_stem "$rel")"

  if [[ "$stem" =~ (UD-)?(IQ[0-9]+_[A-Za-z0-9_]+|TQ[0-9]+_[0-9]+|Q[0-9]+_[A-Za-z0-9_]+|BF16|F16|F32|MXFP[0-9]+(_MOE)?)(-mtp)?$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
    return 0
  fi

  printf '%s\n' "$stem"
}

model_id_base() {
  local rel="$1"
  local quant="$2"
  local first second rest

  IFS=/ read -r first second rest <<< "$rel"
  if [[ -n "${first:-}" && -n "${second:-}" && -n "${rest:-}" ]]; then
    printf '%s/%s:%s\n' "$first" "$second" "$quant"
    return 0
  fi

  if [[ -n "${first:-}" && -n "${second:-}" ]]; then
    printf '%s:%s\n' "$first" "$quant"
    return 0
  fi

  printf '%s\n' "$(filename_stem "$rel")"
}

unique_model_id() {
  local base_id="$1"
  local rel="$2"
  local candidate="$base_id"
  local stem n

  if [[ -z "${seen_ids[$candidate]:-}" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  stem="$(filename_stem "$rel")"
  candidate="$base_id:$stem"
  n=2
  while [[ -n "${seen_ids[$candidate]:-}" ]]; do
    candidate="$base_id:$stem:$n"
    n=$((n + 1))
  done

  printf '%s\n' "$candidate"
}

container_path() {
  local rel="$1"
  printf '%s/%s\n' "$CONTAINER_MODELS_DIR" "$rel"
}

find_mmproj() {
  local host_file="$1"
  local model_rel="$2"
  local model_dir rel_dir rel_mmproj
  local mmprojs=()

  model_dir="$(dirname "$host_file")"
  rel_dir="$(dirname "$model_rel")"
  mapfile -t mmprojs < <(find -L "$model_dir" -maxdepth 1 -type f -iname '*mmproj*.gguf' -printf '%f\n' | sort)

  case "${#mmprojs[@]}" in
    0)
      return 0
      ;;
    1)
      if [[ "$rel_dir" == "." ]]; then
        rel_mmproj="${mmprojs[0]}"
      else
        rel_mmproj="$rel_dir/${mmprojs[0]}"
      fi
      printf '%s\n' "$(container_path "$rel_mmproj")"
      ;;
    *)
      echo "generate-models-preset: warning: multiple mmproj files beside $model_rel; omitting mmproj" >&2
      return 0
      ;;
  esac
}

is_qwen_model() {
  local rel="$1"
  [[ "$rel" =~ [Qq]wen ]]
}

is_mtp_model() {
  local rel="$1"
  [[ "$rel" =~ MTP || "$rel" =~ mtp ]]
}

is_crown_halo_mtp_dynamic_model() {
  local rel="$1"
  [[ "$rel" =~ [Qq]wen3\.6-35[Bb]-[Aa]3[Bb].*[Hh]alo[Ss]trix-[Dd]yn-[Mm][Tt][Pp]-v7 ]] ||
    [[ "$rel" =~ qwen3\.6-35b-a3b-crown-halo-mtp-dynamic ]]
}

is_rocmfp4_llamacpp_model() {
  local rel="$1"
  [[ "$rel" =~ [Rr][Oo][Cc][Mm][Ff][Pp]4 ]] ||
    [[ "$rel" =~ [Cc][Hh][Aa][Dd][Rr][Oo][Cc][Kk]3\.6-35[Bb]-UNCENSORED-MTP-STRIX-LEAN ]]
}

is_qwopus_27b_coder_rocmfp4_model() {
  local rel="$1"
  [[ "$rel" =~ [Qq]wopus3\.6-27[Bb]-[Cc]oder-[Mm][Tt][Pp]-[Rr][Oo][Cc][Mm][Ff][Pp]4 ]]
}

rocmfp4_alias_base() {
  local rel="$1"

  case "$rel" in
    *chadrock-35b-ace-saber-rocmfp4-mtp*|*Qwen3.6-35B-A3B-NSC-ACE-SABER-MTP-F16-to-ROCmFP4-STRIX_LEAN*)
      printf '%s\n' chadrock-35b-ace-saber
      ;;
    *CHADROCK3.6-35B-UNCENSORED-MTP-STRIX-LEAN*|*chadrock3.6-35b-uncensored-mtp-strix-lean*)
      printf '%s\n' chadrock-35b-uncensored
      ;;
    *qwopus3.6-27b-v2-chadrock-rocmfp4-mtp*|*Qwopus3.6-27B-v2-MTP-BF16-to-ROCmFP4-STRIX_LEAN*)
      printf '%s\n' qwopus-27b-v2-chadrock
      ;;
    *Qwopus3.6-27B-v2-MTP-Q4_0_ROCMFP4*|*qwopus3.6-27b-v2-mtp-q4_0_rocmfp4*)
      printf '%s\n' qwopus-27b-v2
      ;;
    *Qwopus3.6-35B-A3B-v1-MTP-Q4_0_ROCMFP4*|*qwopus3.6-35b-a3b-v1-mtp-q4_0_rocmfp4*)
      printf '%s\n' qwopus-35b-a3b-v1
      ;;
    *)
      filename_stem "$rel" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
      ;;
  esac
}

emit_model_section() {
  local id="$1"
  local model_path="$2"
  local mmproj_path="$3"
  local mtp="$4"

  printf '\n[%s]\n' "$id"
  printf 'model = %s\n' "$model_path"
  if [[ -n "$mmproj_path" ]]; then
    printf 'mmproj = %s\n' "$mmproj_path"
  fi
  if [[ "$mtp" == "1" ]]; then
    printf 'spec-type = draft-mtp,ngram-map-k4v\n'
    printf 'spec-draft-n-max = 3\n'
    printf 'spec-draft-type-k = q8_0\n'
    printf 'spec-draft-type-v = q8_0\n'
    printf 'spec-ngram-map-k4v-size-n = 16\n'
    printf 'spec-ngram-map-k4v-size-m = 24\n'
    printf 'spec-ngram-map-k4v-min-hits = 2\n'
  fi
}

emit_crown_halo_mtp_dynamic_section() {
  local id="$1"
  local model_path="$2"
  local reasoning="$3"
  local alias="$4"

  emit_model_section "$id" "$model_path" "" 0
  printf 'alias = %s\n' "$alias"
  printf 'ctx-size = 131072\n'
  printf 'reasoning = %s\n' "$reasoning"
  if [[ "$reasoning" == "off" ]]; then
    printf 'reasoning-format = none\n'
  fi
  printf 'reasoning-budget = -1\n'
  printf 'context-shift = off\n'
  printf 'split-mode = row\n'
  printf 'n-gpu-layers = 999\n'
  printf 'flash-attn = on\n'
  printf 'batch-size = 2048\n'
  printf 'ubatch-size = 512\n'
  printf 'threads = 16\n'
  printf 'cache-type-k = f16\n'
  printf 'cache-type-v = f16\n'
  printf 'spec-type = draft-mtp\n'
  printf 'spec-draft-n-max = 4\n'
  printf 'spec-draft-type-k = f16\n'
  printf 'spec-draft-type-v = f16\n'
  printf 'parallel = 1\n'
  printf 'metrics = true\n'
  printf 'no-mmproj = true\n'
  printf 'poll = 100\n'
  printf 'poll-batch = 1\n'
  printf 'spec-draft-poll = 1\n'
  printf 'spec-draft-poll-batch = 1\n'
  printf 'temp = 0.6\n'
  printf 'min-p = 0.0\n'
  printf 'top-p = 0.95\n'
  printf 'top-k = 20\n'
  printf 'repeat-penalty = 1.0\n'
}

emit_crown_halo_mtp_dynamic_variants() {
  local id="$1"
  local model_path="$2"

  emit_crown_halo_mtp_dynamic_section "$id:mtp" "$model_path" on crown-dynamic-mtp-reasoning
  emit_crown_halo_mtp_dynamic_section "$id:mtp:non-reasoning" "$model_path" off crown-dynamic-mtp
}

emit_rocmfp4_mtp_section() {
  local id="$1"
  local model_path="$2"
  local reasoning="$3"
  local alias="$4"

  emit_model_section "$id" "$model_path" "" 0
  printf 'alias = %s\n' "$alias"
  printf 'ctx-size = 262144\n'
  printf 'reasoning = %s\n' "$reasoning"
  printf 'parallel = 1\n'
  printf 'jinja = true\n'
  printf 'n-gpu-layers = 999\n'
  printf 'flash-attn = on\n'
  printf 'device = %s\n' "$ROCMFP4_DEVICE"
  printf 'batch-size = 512\n'
  printf 'ubatch-size = 512\n'
  printf 'threads = 16\n'
  printf 'threads-batch = 32\n'
  printf 'cache-type-k = q8_0\n'
  printf 'cache-type-v = q8_0\n'
  printf 'spec-type = draft-mtp\n'
  printf 'spec-draft-device = %s\n' "$ROCMFP4_DEVICE"
  printf 'spec-draft-ngl = all\n'
  printf 'spec-draft-type-k = q4_0\n'
  printf 'spec-draft-type-v = q4_0\n'
  printf 'spec-draft-n-max = 3\n'
  printf 'spec-draft-n-min = 0\n'
  printf 'spec-draft-p-min = 0.0\n'
  printf 'spec-draft-p-split = 0.10\n'
  # printf 'metrics = true\n'
  printf 'mmap = off\n'
}

emit_rocmfp4_mtp_variants() {
  local id="$1"
  local model_path="$2"
  local alias_base="$3"

  emit_rocmfp4_mtp_section "$id:mtp" "$model_path" on "$alias_base"
  emit_rocmfp4_mtp_section "$id:mtp:non-reasoning" "$model_path" off "$alias_base-non-reasoning"
}

emit_qwopus_27b_coder_rocmfp4_section() {
  local id="$1"
  local model_path="$2"
  local reasoning="$3"
  local alias="$4"

  emit_model_section "$id" "$model_path" "" 0
  printf 'alias = %s\n' "$alias"
  printf 'ctx-size = 262144\n'
  printf 'reasoning = %s\n' "$reasoning"
  if [[ "$reasoning" == "off" ]]; then
    printf 'reasoning-format = none\n'
  else
    printf 'reasoning-format = deepseek\n'
  fi
  printf 'chat-template-kwargs = {"preserve_thinking": true}\n'
  printf 'parallel = 1\n'
  printf 'jinja = true\n'
  printf 'n-gpu-layers = 999\n'
  printf 'flash-attn = on\n'
  printf 'device = %s\n' "$ROCMFP4_DEVICE"
  printf 'batch-size = 2048\n'
  printf 'ubatch-size = 512\n'
  printf 'threads = 16\n'
  printf 'threads-batch = 16\n'
  printf 'cache-type-k = f16\n'
  printf 'cache-type-v = f16\n'
  printf 'ctx-checkpoints = 32\n'
  # This is not accepted by the current custom fork of llama.cpp
  # printf 'checkpoint-min-step = 256\n'
  printf 'cache-reuse = 256\n'
  printf 'temp = 0.6\n'
  printf 'top-p = 0.95\n'
  printf 'top-k = 20\n'
  printf 'min-p = 0.0\n'
  printf 'spec-type = draft-mtp\n'
  printf 'spec-draft-device = %s\n' "$ROCMFP4_DEVICE"
  printf 'spec-draft-ngl = all\n'
  printf 'spec-draft-type-k = f16\n'
  printf 'spec-draft-type-v = f16\n'
  printf 'spec-draft-n-max = 3\n'
  printf 'spec-draft-n-min = 0\n'
  printf 'spec-draft-p-min = 0.0\n'
  printf 'spec-draft-p-split = 0.10\n'
  printf 'mmap = off\n'
}

emit_qwopus_27b_coder_rocmfp4_variants() {
  local id="$1"
  local model_path="$2"
  local alias_base="qwopus3.6-27b-coder-rocmfp4"

  case "${model_path##*/}" in
    *headQ6*|*headq6*)
      alias_base="$alias_base-headq6"
      ;;
  esac

  emit_qwopus_27b_coder_rocmfp4_section "$id:mtp" "$model_path" on "$alias_base-mtp"
  emit_qwopus_27b_coder_rocmfp4_section "$id:mtp:non-reasoning" "$model_path" off "$alias_base-mtp-non-reasoning"
}

emit_non_reasoning_section() {
  local id="$1"
  local model_path="$2"
  local mmproj_path="$3"
  local mtp="$4"

  emit_model_section "$id:non-reasoning" "$model_path" "$mmproj_path" "$mtp"
  printf 'reasoning = off\n'
  printf 'temp = 0.7\n'
  printf 'top-p = 0.8\n'
  printf 'presence-penalty = 1.5\n'
}

emit_model_variants() {
  local id="$1"
  local model_path="$2"
  local mmproj_path="$3"
  local mtp="$4"
  local qwen="$5"

  emit_model_section "$id" "$model_path" "$mmproj_path" "$mtp"
  if (( WITH_NON_REASONING )) && (( qwen )); then
    emit_non_reasoning_section "$id" "$model_path" "$mmproj_path" "$mtp"
  fi
}

MODELS_DIR="$(trim_trailing_slash "$MODELS_DIR")"
CONTAINER_MODELS_DIR="$(trim_trailing_slash "$CONTAINER_MODELS_DIR")"

if [[ "$OUTPUT" == "/dev/stdout" ]]; then
  tmp_output="$(mktemp "${TMPDIR:-/tmp}/llama-models.XXXXXX.ini")"
else
  tmp_output="${OUTPUT}.tmp.$$"
fi
trap 'rm -f "$tmp_output"' EXIT

if (( ROCMFP4_ONLY )); then
  awk '
    /^[[:space:]]*checkpoint-min-step[[:space:]]*=/ { next }
    { print }
    /^# --- GENERATED MODEL SECTIONS ---$/ { exit }
  ' "$TEMPLATE" > "$tmp_output"
else
  awk '
    { print }
    /^# --- GENERATED MODEL SECTIONS ---$/ { exit }
  ' "$TEMPLATE" > "$tmp_output"
fi

declare -A seen_ids=()
model_count=0

while IFS= read -r host_file; do
  rel="${host_file#"$MODELS_DIR"/}"
  base="${rel##*/}"
  if [[ "$base" =~ [Mm][Mm][Pp][Rr][Oo][Jj] ]]; then
    continue
  fi

  if (( ROCMFP4_ONLY )); then
    if ! is_rocmfp4_llamacpp_model "$rel"; then
      continue
    fi
  elif is_rocmfp4_llamacpp_model "$rel"; then
    continue
  fi

  quant="$(infer_quant "$rel")"
  id="$(unique_model_id "$(model_id_base "$rel" "$quant")" "$rel")"
  seen_ids[$id]=1

  model_path="$(container_path "$rel")"
  mtp=0
  if is_mtp_model "$rel"; then
    mtp=1
  fi
  qwen=0
  if is_qwen_model "$rel"; then
    qwen=1
  fi

  if is_crown_halo_mtp_dynamic_model "$rel"; then
    emit_crown_halo_mtp_dynamic_variants "$id" "$model_path" >> "$tmp_output"
    model_count=$((model_count + 1))
    continue
  fi

  if is_rocmfp4_llamacpp_model "$rel"; then
    if is_qwopus_27b_coder_rocmfp4_model "$rel"; then
      emit_qwopus_27b_coder_rocmfp4_variants "$id" "$model_path" >> "$tmp_output"
      model_count=$((model_count + 1))
      continue
    fi

    emit_rocmfp4_mtp_variants "$id" "$model_path" "$(rocmfp4_alias_base "$rel")" >> "$tmp_output"
    model_count=$((model_count + 1))
    continue
  fi

  emit_model_variants "$id" "$model_path" "" 0 "$qwen" >> "$tmp_output"
  if (( mtp )); then
    emit_model_variants "$id:mtp" "$model_path" "" 1 "$qwen" >> "$tmp_output"
  fi

  if (( WITH_VISION )); then
    mmproj_path="$(find_mmproj "$host_file" "$rel")"
    if [[ -n "$mmproj_path" ]]; then
      vision_id="$id:vision"
      emit_model_variants "$vision_id" "$model_path" "$mmproj_path" 0 "$qwen" >> "$tmp_output"
      if (( mtp )); then
        emit_model_variants "$vision_id:mtp" "$model_path" "$mmproj_path" 1 "$qwen" >> "$tmp_output"
      fi
    fi
  fi

  model_count=$((model_count + 1))
done < <(find -L "$MODELS_DIR" -type f -name '*.gguf' -printf '%p\n' | sort)

if (( model_count == 0 )) && (( ROCMFP4_ONLY )); then
  echo "generate-models-preset: warning: no ROCmFP4 llama.cpp GGUF models found under $MODELS_DIR" >&2
elif (( model_count == 0 )); then
  echo "generate-models-preset: warning: no non-mmproj GGUF models found under $MODELS_DIR" >&2
fi

if (( WITH_CONFIGS )); then
  "$PROJECT_ROOT/bin/generate-coding-tool-configs.ts" \
    --output-root "$PROJECT_ROOT/coding-tool-configs" \
    "$tmp_output" >&2
fi

if [[ "$OUTPUT" == "/dev/stdout" ]]; then
  cat "$tmp_output"
else
  mv "$tmp_output" "$OUTPUT"
  trap - EXIT
fi
