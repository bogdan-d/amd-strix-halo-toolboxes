#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bin/generate-models-preset.sh [--with-non-reasoning] [--with-vision] [--with-configs] <models-dir> <container-models-dir> <template> [output]

Generate a llama.cpp --models-preset INI by copying shared defaults from the
tracked template and appending discovered GGUF model sections.

Options:
  --with-non-reasoning  Add Qwen/Qwen-derived :non-reasoning variants.
  --with-vision         Add :vision variants for models with one paired mmproj GGUF.
  --with-configs        Refresh coding-tool configs from the generated preset.
EOF
}

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WITH_NON_REASONING=0
WITH_VISION=0
WITH_CONFIGS=0

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

awk '
  { print }
  /^# --- GENERATED MODEL SECTIONS ---$/ { exit }
' "$TEMPLATE" > "$tmp_output"

declare -A seen_ids=()
model_count=0

while IFS= read -r host_file; do
  rel="${host_file#"$MODELS_DIR"/}"
  base="${rel##*/}"
  if [[ "$base" =~ [Mm][Mm][Pp][Rr][Oo][Jj] ]]; then
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

if (( model_count == 0 )); then
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
