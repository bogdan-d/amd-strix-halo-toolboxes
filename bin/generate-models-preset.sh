#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bin/generate-models-preset.sh [--with-non-reasoning] [--with-vision] [--with-configs] [--rocmfpx-only] [--device DEVICE] <models-dir> <container-models-dir> <template> [output]

Generate a llama.cpp --models-preset INI by copying shared defaults from the
tracked template and appending discovered GGUF model sections.

Options:
  --with-non-reasoning  Add Qwen/Qwen-derived :non-reasoning variants.
  --with-vision         Add :vision variants for models with one paired mmproj GGUF.
  --with-configs        Refresh coding-tool configs from the generated preset.
  --rocmfpx-only        Generate only ROCmFPX presets for the custom fork image.
  --device              Device name for all generated presets. Default: ROCm0.
  --fpx-only            Alias for --rocmfpx-only.
EOF
}

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WITH_NON_REASONING=0
WITH_VISION=0
WITH_CONFIGS=0
ROCMFPX_ONLY=0
LLAMA_DEVICE=ROCm0

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
    --rocmfpx-only|--fpx-only)
      ROCMFPX_ONLY=1
      shift
      ;;
    --device)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        echo "Missing value for --device" >&2
        usage >&2
        exit 1
      fi
      LLAMA_DEVICE="$2"
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

model_id_base() {
  local rel="$1"
  local first second rest

  IFS=/ read -r first second rest <<< "$rel"
  if [[ -n "${first:-}" && -n "${second:-}" ]]; then
    printf '%s/%s\n' "$first" "$(filename_stem "$rel")"
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

is_rocmfpx_llamacpp_model() {
  local rel="$1"
  [[ "$rel" =~ [Rr][Oo][Cc][Mm][Ff][Pp][Xx] ]] ||
    [[ "$rel" =~ [Rr][Oo][Cc][Mm][Ff][Pp][3468] ]] ||
    [[ "$rel" =~ [Cc][Hh][Aa][Dd][Rr][Oo][Cc][Kk]3\.6-35[Bb]-UNCENSORED-MTP-STRIX-LEAN ]]
}

is_qwopus_27b_coder_rocmfpx_model() {
  local rel="$1"
  [[ "$rel" =~ [Qq]wopus3\.6-27[Bb]-[Cc]oder-[Mm][Tt][Pp]-[Rr][Oo][Cc][Mm][Ff][Pp][4Xx] ]]
}

is_nex_n2_mini_rocmfpx_model() {
  local rel="$1"
  [[ "$rel" =~ [Nn]ex-[Nn]2-mini-[Rr][Oo][Cc][Mm][Ff][Pp][4Xx] ]]
}

model_author() {
  local rel="$1"
  local first second rest

  IFS=/ read -r first second rest <<< "$rel"
  if [[ -n "${first:-}" && -n "${second:-}" && -n "${rest:-}" ]]; then
    printf '%s\n' "$first"
    return 0
  fi

  printf '%s\n' local
}

is_uncensored_model() {
  local rel="$1"
  [[ "$rel" =~ [Uu][Nn][Cc][Ee][Nn][Ss][Oo][Rr][Ee][Dd] ]] ||
    [[ "$rel" =~ [AaOo][Bb][Ll][Ii][Tt][Ee][Rr][Aa][Tt][Ee][Dd] ]] ||
    [[ "$rel" =~ (^|[-_/])[Oo][Bb][Ll][Ii][Tt][Ee][Rr][Aa][Tt][Ee][Dd]($|[-_/]) ]] ||
    [[ "$rel" =~ (^|[-_/])[Uu][Nn][Cc]($|[-_/]) ]]
}

is_moe_model() {
  local rel="$1"
  [[ "$rel" =~ [Aa][0-9]+[Bb] ]] ||
    [[ "$rel" =~ [Mm][Oo][Ee] ]] ||
    [[ "$rel" =~ MXFP[0-9]+_MOE ]]
}

is_imatrix_model() {
  local rel="$1"
  [[ "$rel" =~ (^|[-_/])[Ii][Mm][Aa][Tt][Rr][Ii][Xx]($|[-_/]) ]]
}

model_size_label() {
  local host_file="$1"

  du -BG --apparent-size "$host_file" | cut -f1
}

clean_alias_model_name() {
  local value="$1"

  value="$(printf '%s\n' "$value" | sed -E \
    -e 's/[-_][Gg][Gg][Uu][Ff]$//' \
    -e 's/-+/-/g' \
    -e 's/_+/_/g' \
    -e 's/-_+/-/g' \
    -e 's/_-+/_/g' \
    -e 's/^[-_]+//' \
    -e 's/[-_]+$//')"
  if [[ -z "$value" ]]; then
    value=model
  fi
  printf '%s\n' "$value"
}

alias_remove_token() {
  local value="$1"
  local token_re="$2"

  printf '%s\n' "$value" | sed -E \
    -e "s/(^|[-_])${token_re}($|[-_])/-/Ig" \
    -e 's/-+/-/g' \
    -e 's/_+/_/g' \
    -e 's/-_+/-/g' \
    -e 's/_-+/_/g' \
    -e 's/^[-_]+//' \
    -e 's/[-_]+$//'
}

generic_alias_parts() {
  local host_file="$1"
  local rel="$2"
  local mtp_enabled="$3"
  local non_reasoning="$4"
  local vision_enabled="$5"
  local stem model_name author quant="" weight="" active="" fpx="" fpx_char="" size_on_disk

  stem="$(filename_stem "$rel")"
  model_name="$stem"
  author="$(model_author "$rel")"

  # Strip feature and size tokens first. Remaining cleaned stem is display name.
  if [[ "$model_name" =~ [Rr][Oo][Cc][Mm][Ff][Pp]([Xx0-9]) ]]; then
    fpx_char="${BASH_REMATCH[1]}"
    if [[ "$fpx_char" =~ [Xx] ]]; then
      fpx="FPX"
    else
      fpx="FP${fpx_char}"
    fi
    model_name="$(alias_remove_token "$model_name" '[Rr][Oo][Cc][Mm][Ff][Pp][Xx0-9]')"
  fi

  model_name="$(alias_remove_token "$model_name" '([Tt][Hh][Ii][Nn][Kk][Ii][Nn][Gg]|[Rr][Ee][Aa][Ss][Oo][Nn][Ii][Nn][Gg])')"

  if is_uncensored_model "$rel" || [[ "$rel" =~ [Hh][Ee][Rr][Ee][Tt][Ii][Cc] ]]; then
    model_name="$(alias_remove_token "$model_name" '([Uu][Nn][Cc][Ee][Nn][Ss][Oo][Rr][Ee][Dd]|[Hh][Ee][Rr][Ee][Tt][Ii][Cc]|[AaOo][Bb][Ll][Ii][Tt][Ee][Rr][Aa][Tt][Ee][Dd]|[Uu][Nn][Cc])')"
  fi

  if is_mtp_model "$rel"; then
    model_name="$(alias_remove_token "$model_name" '[Mm][Tt][Pp]')"
  fi

  if [[ "$model_name" =~ (^|[-_])((UD-)?(IQ[0-9]+_[A-Za-z0-9_]+|TQ[0-9]+_[0-9]+|Q[0-9]+_[A-Za-z0-9_]+|BF16|F16|F32|MXFP[0-9]+(_MOE)?))($|[-_]) ]]; then
    quant="${BASH_REMATCH[2]}"
    model_name="$(alias_remove_token "$model_name" "$quant")"
  fi
  model_name="$(alias_remove_token "$model_name" '[Tt][Oo]')"

  if [[ "$model_name" =~ ([0-9]+[BbMm])-[Aa]([0-9]+[BbMm]) ]]; then
    weight="${BASH_REMATCH[1]}"
    active="A${BASH_REMATCH[2]}"
    model_name="$(alias_remove_token "$model_name" "${BASH_REMATCH[1]}-[Aa]${BASH_REMATCH[2]}")"
  elif [[ "$model_name" =~ (^|[-_])([0-9]+[BbMm])($|[-_]) ]]; then
    weight="${BASH_REMATCH[2]}"
    model_name="$(alias_remove_token "$model_name" "$weight")"
  fi

  model_name="$(clean_alias_model_name "$model_name")"
  size_on_disk="$(model_size_label "$host_file")"

  printf '[%s] %s' "$author" "$model_name"
  if [[ -n "$weight" && -n "$active" ]]; then
    printf ' [%s / %s]' "$weight" "$active"
  elif [[ -n "$weight" ]]; then
    printf ' [%s]' "$weight"
  fi
  if [[ -n "$quant" ]]; then
    printf ' [%s]' "$quant"
  fi
  if (( mtp_enabled )); then
    printf ' [MTP]'
  fi
  if (( non_reasoning )); then
    printf ' [NO-THINK]'
  fi
  if is_uncensored_model "$rel" || [[ "$rel" =~ [Hh][Ee][Rr][Ee][Tt][Ii][Cc] ]]; then
    printf ' [UNC]'
  fi
  if [[ -n "$fpx" ]]; then
    printf ' [%s]' "$fpx"
  fi
  if (( vision_enabled )); then
    printf ' [VISION]'
  fi
  printf ' [%s]\n' "$size_on_disk"
}

rocmfpx_alias_quant() {
  local rel="$1"
  local stem haystack

  stem="$(filename_stem "$rel")"
  haystack="$rel"
  if [[ "$haystack" =~ (Q[3468]_0)_ROCMFP[4X] ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$haystack" =~ (Q[0-9]+_[A-Za-z0-9_]+)_ROCMFP[4Xx] ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$stem" =~ (UD-)?(IQ[0-9]+_[A-Za-z0-9_]+|TQ[0-9]+_[0-9]+|Q[0-9]+_[A-Za-z0-9_]+|BF16|F16|F32|MXFP[0-9]+(_MOE)?)(-to-[Rr][Oo][Cc][Mm][Ff][Pp]([4Xx])|-mtp)?$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
    return 0
  fi
  if [[ "$haystack" =~ [Rr][Oo][Cc][Mm][Ff][Pp]3 ]]; then
    printf '%s\n' ROCmFP3
    return 0
  fi
  if [[ "$haystack" =~ [Rr][Oo][Cc][Mm][Ff][Pp]4 ]]; then
    printf '%s\n' ROCmFP4
    return 0
  fi
  if [[ "$haystack" =~ [Rr][Oo][Cc][Mm][Ff][Pp]6 ]]; then
    printf '%s\n' ROCmFP6
    return 0
  fi
  if [[ "$haystack" =~ [Rr][Oo][Cc][Mm][Ff][Pp]8 ]]; then
    printf '%s\n' ROCmFP8
    return 0
  fi
  if [[ "$haystack" =~ [Rr][Oo][Cc][Mm][Ff][Pp][Xx] ]]; then
    printf '%s\n' ROCmFPX
  fi
}

rocmfpx_alias_model_name() {
  local rel="$1"
  local stem base_name_re first second rest

  case "$rel" in
    *Nex-N2-mini-ROCmFP4*|*nex-n2-mini-rocmfp4*|*Nex-N2-mini-ROCmFPX*|*nex-n2-mini-rocmfpx*)
      printf '%s\n' Nex-N2-mini
      return 0
      ;;
    *chadrock-35b-ace-saber-rocmfp4-mtp*|*Qwen3.6-35B-A3B-NSC-ACE-SABER-MTP-F16-to-ROCmFP4-STRIX_LEAN*)
      printf '%s\n' Chadrock3.6-35B-A3B-ACE-SABER
      return 0
      ;;
    *CHADROCK3.6-35B-UNCENSORED-MTP-STRIX-LEAN*|*chadrock3.6-35b-uncensored-mtp-strix-lean*)
      printf '%s\n' Chadrock3.6-35B
      return 0
      ;;
    *qwopus3.6-27b-v2-chadrock-rocmfp4-mtp*|*Qwopus3.6-27B-v2-MTP-BF16-to-ROCmFP4-STRIX_LEAN*)
      printf '%s\n' Qwopus3.6-27B-v2-Chadrock
      return 0
      ;;
    *Qwopus3.6-27B-v2-MTP-Q4_0_ROCMFP4*|*qwopus3.6-27b-v2-mtp-q4_0_rocmfp4*)
      printf '%s\n' Qwopus3.6-27B-v2
      return 0
      ;;
    *Qwopus3.6-35B-A3B-v1-MTP-Q4_0_ROCMFP4*|*qwopus3.6-35b-a3b-v1-mtp-q4_0_rocmfp4*)
      printf '%s\n' Qwopus3.6-35B-A3B-v1
      return 0
      ;;
  esac

  stem="$(filename_stem "$rel")"
  IFS=/ read -r first second rest <<< "$rel"
  if [[ "$stem" =~ ^[Mm][Oo][Dd][Ee][Ll](-[0-9]+)?$ && -n "${second:-}" ]]; then
    stem="$second"
  fi
  base_name_re='(^|[-_/])((Qwen|Qwopus|Chadrock|Nex|DeepSeek|Llama|Mistral|Mixtral|Gemma|Phi)[A-Za-z0-9.]*[-_][0-9]+(\.[0-9]+)?[Bb]([-_][A-Za-z][0-9]+[Bb])?([-_][Vv][0-9]+)?)'
  if [[ "$stem" =~ $base_name_re ]]; then
    printf '%s\n' "${BASH_REMATCH[2]//_/-}"
    return 0
  fi

  stem="$(printf '%s\n' "$stem" | sed -E \
    -e 's/[-_][Gg][Gg][Uu][Ff]$//' \
    -e 's/[-_]?[Ss][Tt][Rr][Ii][Xx][_-]?(LEAN|SPEED|QUALITY)$//' \
    -e 's/[-_]?[Rr][Oo][Cc][Mm][Ff][Pp][Xx]$//' \
    -e 's/[-_]?[Rr][Oo][Cc][Mm][Ff][Pp][3468]$//' \
    -e 's/[-_]?(BF16|F16|F32|Q[0-9]+_[A-Za-z0-9_]+)-to-[Rr][Oo][Cc][Mm][Ff][Pp][Xx]$//' \
    -e 's/[-_]?(BF16|F16|F32|Q[0-9]+_[A-Za-z0-9_]+)-to-[Rr][Oo][Cc][Mm][Ff][Pp][3468]$//' \
    -e 's/[-_]?Q[3468]_0_[Rr][Oo][Cc][Mm][Ff][Pp]([Xx]|4)(_AGENT)?$//' \
    -e 's/[-_]?Q6_0_[Rr][Oo][Cc][Mm][Ff][Pp][Xx]_[Ss][Tt][Rr][Ii][Xx]_(LEAN|SPEED|QUALITY)$//' \
    -e 's/(^|[-_])[Mm][Tt][Pp]($|[-_])/-/g' \
    -e 's/(^|[-_])[Aa][Gg][Ee][Nn][Tt]($|[-_])/-/g' \
    -e 's/(^|[-_])[Uu][Nn][Cc][Ee][Nn][Ss][Oo][Rr][Ee][Dd]($|[-_])/-/g' \
    -e 's/(^|[-_])[Uu][Nn][Cc]($|[-_])/-/g' \
    -e 's/-+/-/g; s/_+/-/g; s/^-+//; s/-+$//')"
  printf '%s\n' "$stem"
}

format_model_alias() {
  local model_name="$1"
  local author="$2"
  local moe="$3"
  local mtp="$4"
  local uncensored="$5"
  local quant="$6"
  shift 6
  local tags=("$@")
  local alias="$model_name"
  local tag

  if (( moe )); then
    alias+=" [MOE]"
  fi
  if (( mtp )); then
    alias+=" [MTP]"
  fi
  if (( uncensored )); then
    alias+=" [UNC]"
  fi
  if [[ -n "$quant" ]]; then
    alias+=" [$quant]"
  fi
  for tag in "${tags[@]}"; do
    if [[ -n "$tag" ]]; then
      alias+=" [$tag]"
    fi
  done
  alias+=" ($author)"
  printf '%s\n' "$alias"
}

unique_alias() {
  local alias="$1"
  local rel="$2"
  local candidate="$alias"
  local prefix author_suffix stem n author_suffix_re

  if [[ -z "${seen_aliases[$candidate]:-}" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  stem="$(filename_stem "$rel" | sed -E 's/[^A-Za-z0-9_]+/-/g; s/^-+//; s/-+$//')"
  author_suffix_re='^(.*)( \([^)]+\))$'
  if [[ "$alias" =~ $author_suffix_re ]]; then
    prefix="${BASH_REMATCH[1]}"
    author_suffix="${BASH_REMATCH[2]}"
    candidate="$prefix [$stem]$author_suffix"
  else
    candidate="$alias [$stem]"
  fi

  n=2
  while [[ -n "${seen_aliases[$candidate]:-}" ]]; do
    if [[ "$alias" =~ $author_suffix_re ]]; then
      candidate="$prefix [$stem $n]$author_suffix"
    else
      candidate="$alias [$stem $n]"
    fi
    n=$((n + 1))
  done

  printf '%s\n' "$candidate"
}

rocmfpx_alias() {
  local rel="$1"
  shift
  local model_name author quant moe mtp uncensored extra_tags

  model_name="$(rocmfpx_alias_model_name "$rel")"
  author="$(model_author "$rel")"
  quant="$(rocmfpx_alias_quant "$rel")"
  moe=0
  if is_moe_model "$rel"; then
    moe=1
  fi
  mtp=0
  if is_mtp_model "$rel"; then
    mtp=1
  fi
  uncensored=0
  if is_uncensored_model "$rel"; then
    uncensored=1
  fi
  extra_tags=()
  if is_imatrix_model "$rel"; then
    extra_tags+=(imatrix)
  fi

  format_model_alias "$model_name" "$author" "$moe" "$mtp" "$uncensored" "$quant" "${extra_tags[@]}" "$@"
}

crown_halo_mtp_dynamic_alias() {
  local rel="$1"
  shift
  format_model_alias "Qwen3.6-35B-A3B-Crown-Halo-Dynamic" "$(model_author "$rel")" 1 1 0 "" "$@"
}

emit_model_section() {
  local id="$1"
  local model_path="$2"
  local mmproj_path="$3"
  local mtp="$4"
  local moe="${5:-0}"
  local skip_ubatch="${6:-0}"

  printf '\n[%s]\n' "$id"
  printf 'model = %s\n' "$model_path"
  printf 'device = %s\n' "$LLAMA_DEVICE"
  if [[ "$LLAMA_DEVICE" == ROCm* ]] && (( ! skip_ubatch )); then
    printf 'ubatch-size = 256\n'
  fi
  if [[ -n "$mmproj_path" ]]; then
    printf 'mmproj = %s\n' "$mmproj_path"
    printf 'image-min-tokens = 1024\n'
  fi
  if [[ "$mtp" == "1" ]]; then
    printf 'spec-type = draft-mtp,ngram-map-k4v\n'
    if (( moe )); then
      printf 'spec-draft-n-max = 2\n'
    else
      printf 'spec-draft-n-max = 3\n'
    fi
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
  local moe="${5:-0}"

  emit_model_section "$id" "$model_path" "" 0 0 1
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
  printf 'spec-type = draft-mtp\n'
  if (( moe )); then
    printf 'spec-draft-n-max = 2\n'
  else
    printf 'spec-draft-n-max = 4\n'
  fi
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
  local rel="$3"
  local moe="${4:-0}"
  local reasoning_alias non_reasoning_alias

  reasoning_alias="$(unique_alias "$(crown_halo_mtp_dynamic_alias "$rel")" "$rel")"
  seen_aliases[$reasoning_alias]=1
  non_reasoning_alias="$(unique_alias "$(crown_halo_mtp_dynamic_alias "$rel" non-reasoning)" "$rel")"
  seen_aliases[$non_reasoning_alias]=1

  emit_crown_halo_mtp_dynamic_section "$id:mtp" "$model_path" on "$reasoning_alias" "$moe"
  emit_crown_halo_mtp_dynamic_section "$id:mtp:non-reasoning" "$model_path" off "$non_reasoning_alias" "$moe"
}

emit_nex_n2_mini_rocmfpx_section() {
  local id="$1"
  local model_path="$2"
  local alias="$3"

  emit_model_section "$id" "$model_path" "" 0 0 1
  printf 'alias = %s\n' "$alias"
  printf 'ctx-size = 131072\n'
  printf 'reasoning = off\n'
  printf 'parallel = 1\n'
  printf 'jinja = true\n'
  printf 'n-gpu-layers = 999\n'
  printf 'flash-attn = on\n'
  printf 'batch-size = 2048\n'
  printf 'ubatch-size = 256\n'
  printf 'cache-reuse = 256\n'
  printf 'temp = 0.6\n'
  printf 'top-p = 0.95\n'
  printf 'top-k = 20\n'
  printf 'min-p = 0.0\n'
  printf 'metrics = true\n'
  printf 'mmap = off\n'
}

emit_rocmfpx_section() {
  local id="$1"
  local model_path="$2"
  local mmproj_path="$3"
  local reasoning="$4"
  local alias="$5"
  local thinking="$6"

  emit_model_section "$id" "$model_path" "$mmproj_path" 0
  printf 'alias = %s\n' "$alias"
  printf 'reasoning = %s\n' "$reasoning"
  if [[ "$thinking" == "off" ]]; then
    printf 'reasoning-format = deepseek\n'
    printf 'chat-template-kwargs = {"enable_thinking": false, "preserve_thinking": true}\n'
  elif [[ "$reasoning" == "off" ]]; then
    printf 'reasoning-format = none\n'
  else
    printf 'reasoning-format = deepseek\n'
  fi
}

emit_rocmfpx_variants() {
  local id="$1"
  local model_path="$2"
  local reasoning_alias="$3"
  local non_reasoning_alias="$4"
  local mmproj_path="$5"
  local thinking="${6:-on}"

  emit_rocmfpx_section "$id" "$model_path" "$mmproj_path" on "$reasoning_alias" "$thinking"
  if (( WITH_NON_REASONING )); then
    emit_rocmfpx_section "$id:non-reasoning" "$model_path" "$mmproj_path" off "$non_reasoning_alias" "$thinking"
  fi
}

emit_rocmfpx_mtp_section() {
  local moe="${7:-0}"
  emit_rocmfpx_section "$@"
  printf 'spec-type = draft-mtp\n'
  printf 'spec-draft-device = %s\n' "$LLAMA_DEVICE"
  printf 'spec-draft-ngl = all\n'
  printf 'spec-draft-type-k = f16\n'
  printf 'spec-draft-type-v = f16\n'
  if (( moe )); then
    printf 'spec-draft-n-max = 2\n'
  else
    printf 'spec-draft-n-max = 5\n'
  fi
  printf 'spec-draft-n-min = 0\n'
  printf 'spec-draft-p-min = 0.0\n'
  printf 'spec-draft-p-split = 0.10\n'
}

emit_rocmfpx_mtp_variants() {
  local id="$1"
  local model_path="$2"
  local reasoning_alias="$3"
  local non_reasoning_alias="$4"
  local mmproj_path="$5"
  local thinking="${6:-on}"
  local moe="${7:-0}"

  emit_rocmfpx_mtp_section "$id:mtp" "$model_path" "$mmproj_path" on "$reasoning_alias" "$thinking" "$moe"
  if (( WITH_NON_REASONING )); then
    emit_rocmfpx_mtp_section "$id:mtp:non-reasoning" "$model_path" "$mmproj_path" off "$non_reasoning_alias" "$thinking" "$moe"
  fi
}

emit_non_reasoning_section() {
  local id="$1"
  local model_path="$2"
  local mmproj_path="$3"
  local mtp="$4"
  local moe="${5:-0}"
  local alias="${6:-}"

  emit_model_section "$id:non-reasoning" "$model_path" "$mmproj_path" "$mtp" "$moe"
  if [[ -n "$alias" ]]; then
    printf 'alias = %s\n' "$alias"
  fi
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
  local moe="${6:-0}"
  local alias="${7:-}"
  local non_reasoning_alias="${8:-}"

  emit_model_section "$id" "$model_path" "$mmproj_path" "$mtp" "$moe"
  if [[ -n "$alias" ]]; then
    printf 'alias = %s\n' "$alias"
  fi
  if (( WITH_NON_REASONING )) && (( qwen )); then
    emit_non_reasoning_section "$id" "$model_path" "$mmproj_path" "$mtp" "$moe" "$non_reasoning_alias"
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

if (( ROCMFPX_ONLY )); then
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
declare -A seen_aliases=()
model_count=0

while IFS= read -r host_file; do
  rel="${host_file#"$MODELS_DIR"/}"
  base="${rel##*/}"
  if [[ "$base" =~ [Mm][Mm][Pp][Rr][Oo][Jj] ]]; then
    continue
  fi

  if (( ROCMFPX_ONLY )); then
    if ! is_rocmfpx_llamacpp_model "$rel"; then
      continue
    fi
  elif is_rocmfpx_llamacpp_model "$rel"; then
    continue
  fi

  id="$(unique_model_id "$(model_id_base "$rel")" "$rel")"
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
  moe=0
  if is_moe_model "$rel"; then
    moe=1
  fi

  if is_crown_halo_mtp_dynamic_model "$rel"; then
    emit_crown_halo_mtp_dynamic_variants "$id" "$model_path" "$rel" "$moe" >> "$tmp_output"
    model_count=$((model_count + 1))
    continue
  fi

  if is_rocmfpx_llamacpp_model "$rel"; then
    if is_nex_n2_mini_rocmfpx_model "$rel"; then
      alias="$(unique_alias "$(rocmfpx_alias "$rel")" "$rel")"
      seen_aliases[$alias]=1
      emit_nex_n2_mini_rocmfpx_section "$id" "$model_path" "$alias" >> "$tmp_output"
      model_count=$((model_count + 1))
      continue
    fi

    thinking=on
    if is_qwopus_27b_coder_rocmfpx_model "$rel"; then
      thinking=off
    fi
    reasoning_alias="$(unique_alias "$(generic_alias_parts "$host_file" "$rel" 0 0 0)" "$rel")"
    seen_aliases[$reasoning_alias]=1
    non_reasoning_alias=""
    if (( WITH_NON_REASONING )); then
      non_reasoning_alias="$(unique_alias "$(generic_alias_parts "$host_file" "$rel" 0 1 0)" "$rel")"
      seen_aliases[$non_reasoning_alias]=1
    fi
    emit_rocmfpx_variants "$id" "$model_path" "$reasoning_alias" "$non_reasoning_alias" "" "$thinking" >> "$tmp_output"
    if is_mtp_model "$rel"; then
      mtp_alias="$(unique_alias "$(generic_alias_parts "$host_file" "$rel" 1 0 0)" "$rel")"
      seen_aliases[$mtp_alias]=1
      mtp_non_reasoning_alias=""
      if (( WITH_NON_REASONING )); then
        mtp_non_reasoning_alias="$(unique_alias "$(generic_alias_parts "$host_file" "$rel" 1 1 0)" "$rel")"
        seen_aliases[$mtp_non_reasoning_alias]=1
      fi
      emit_rocmfpx_mtp_variants "$id" "$model_path" "$mtp_alias" "$mtp_non_reasoning_alias" "" "$thinking" "$moe" >> "$tmp_output"
    fi
    if (( WITH_VISION )); then
      mmproj_path="$(find_mmproj "$host_file" "$rel")"
      if [[ -n "$mmproj_path" ]]; then
        vision_alias="$(unique_alias "$(generic_alias_parts "$host_file" "$rel" 0 0 1)" "$rel")"
        seen_aliases[$vision_alias]=1
        vision_non_reasoning_alias=""
        if (( WITH_NON_REASONING )); then
          vision_non_reasoning_alias="$(unique_alias "$(generic_alias_parts "$host_file" "$rel" 0 1 1)" "$rel")"
          seen_aliases[$vision_non_reasoning_alias]=1
        fi
        emit_rocmfpx_variants "$id:vision" "$model_path" "$vision_alias" "$vision_non_reasoning_alias" "$mmproj_path" "$thinking" >> "$tmp_output"
        if is_mtp_model "$rel"; then
          vision_mtp_alias="$(unique_alias "$(generic_alias_parts "$host_file" "$rel" 1 0 1)" "$rel")"
          seen_aliases[$vision_mtp_alias]=1
          vision_mtp_non_reasoning_alias=""
          if (( WITH_NON_REASONING )); then
            vision_mtp_non_reasoning_alias="$(unique_alias "$(generic_alias_parts "$host_file" "$rel" 1 1 1)" "$rel")"
            seen_aliases[$vision_mtp_non_reasoning_alias]=1
          fi
          emit_rocmfpx_mtp_variants "$id:vision" "$model_path" "$vision_mtp_alias" "$vision_mtp_non_reasoning_alias" "$mmproj_path" "$thinking" "$moe" >> "$tmp_output"
        fi
      fi
    fi
    model_count=$((model_count + 1))
    continue
  fi

  alias="$(unique_alias "$(generic_alias_parts "$host_file" "$rel" 0 0 0)" "$rel")"
  seen_aliases[$alias]=1
  non_reasoning_alias=""
  if (( WITH_NON_REASONING )) && (( qwen )); then
    non_reasoning_alias="$(unique_alias "$(generic_alias_parts "$host_file" "$rel" 0 1 0)" "$rel")"
    seen_aliases[$non_reasoning_alias]=1
  fi
  emit_model_variants "$id" "$model_path" "" 0 "$qwen" "$moe" "$alias" "$non_reasoning_alias" >> "$tmp_output"
  if (( mtp )); then
    mtp_alias="$(unique_alias "$(generic_alias_parts "$host_file" "$rel" 1 0 0)" "$rel")"
    seen_aliases[$mtp_alias]=1
    mtp_non_reasoning_alias=""
    if (( WITH_NON_REASONING )) && (( qwen )); then
      mtp_non_reasoning_alias="$(unique_alias "$(generic_alias_parts "$host_file" "$rel" 1 1 0)" "$rel")"
      seen_aliases[$mtp_non_reasoning_alias]=1
    fi
    emit_model_variants "$id:mtp" "$model_path" "" 1 "$qwen" "$moe" "$mtp_alias" "$mtp_non_reasoning_alias" >> "$tmp_output"
  fi

  if (( WITH_VISION )); then
    mmproj_path="$(find_mmproj "$host_file" "$rel")"
    if [[ -n "$mmproj_path" ]]; then
      vision_id="$id:vision"
      vision_alias="$(unique_alias "$(generic_alias_parts "$host_file" "$rel" 0 0 1)" "$rel")"
      seen_aliases[$vision_alias]=1
      vision_non_reasoning_alias=""
      if (( WITH_NON_REASONING )) && (( qwen )); then
        vision_non_reasoning_alias="$(unique_alias "$(generic_alias_parts "$host_file" "$rel" 0 1 1)" "$rel")"
        seen_aliases[$vision_non_reasoning_alias]=1
      fi
      emit_model_variants "$vision_id" "$model_path" "$mmproj_path" 0 "$qwen" "$moe" "$vision_alias" "$vision_non_reasoning_alias" >> "$tmp_output"
      if (( mtp )); then
        vision_mtp_alias="$(unique_alias "$(generic_alias_parts "$host_file" "$rel" 1 0 1)" "$rel")"
        seen_aliases[$vision_mtp_alias]=1
        vision_mtp_non_reasoning_alias=""
        if (( WITH_NON_REASONING )) && (( qwen )); then
          vision_mtp_non_reasoning_alias="$(unique_alias "$(generic_alias_parts "$host_file" "$rel" 1 1 1)" "$rel")"
          seen_aliases[$vision_mtp_non_reasoning_alias]=1
        fi
        emit_model_variants "$vision_id:mtp" "$model_path" "$mmproj_path" 1 "$qwen" "$moe" "$vision_mtp_alias" "$vision_mtp_non_reasoning_alias" >> "$tmp_output"
      fi
    fi
  fi

  model_count=$((model_count + 1))
done < <(find -L "$MODELS_DIR" -type f -name '*.gguf' -printf '%p\n' | sort)

if (( model_count == 0 )) && (( ROCMFPX_ONLY )); then
  echo "generate-models-preset: warning: no ROCmFPX llama.cpp GGUF models found under $MODELS_DIR" >&2
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
