# ROCmFPX Fork Notes

This document records the local reading of the `charlie12345/ROCmFPX` fork used
by the `vulkan-fpx`, `rocm-fpx`, and `rocm-next-fpx` images.

Primary source files inspected:

- <https://github.com/charlie12345/ROCmFPX/blob/experimental-rocmfpx-branch/README.md>
- <https://github.com/charlie12345/ROCmFPX/blob/experimental-rocmfpx-branch/CMakePresets.json>
- <https://github.com/charlie12345/ROCmFPX/blob/experimental-rocmfpx-branch/scripts/build-strix-rocmfp4-mtp.sh>
- <https://github.com/charlie12345/ROCmFPX/blob/experimental-rocmfpx-branch/scripts/run-rocmfpx-mtp-server.sh>
- <https://github.com/charlie12345/ROCmFPX/blob/main/README.md>
- <https://github.com/charlie12345/ROCmFPX/blob/main/ggml/rocmfpx/README.md>
- <https://github.com/charlie12345/ROCmFPX/blob/main/docs/ROCmFPX-EXPERIMENT.md>
- <https://github.com/charlie12345/ROCmFPX/blob/main/docs/ROCmFPX-HANDOFF.md>
- <https://github.com/charlie12345/ROCmFPX/blob/main/scripts/quantize-rocmfpx-agent.sh>
- <https://github.com/charlie12345/ROCmFPX/blob/main/src/llama-quant.cpp>
- <https://github.com/charlie12345/ROCmFPX/blob/main/tools/quantize/quantize.cpp>

## What The Fork Is

ROCmFPX is an experimental AMD-focused llama.cpp fork with custom GGUF
model-weight tensor formats and matching CPU, ROCm/HIP, and Vulkan coverage.
It is not only a K/V-cache compression experiment.

The model-weight family is:

| Family | GGUF tensor type | Block layout | Role |
| --- | --- | --- | --- |
| ROCmFP3 | `Q3_0_ROCMFPX` | 32 weights, packed 3-bit codes, two UE4M3 scales | Smallest experimental ROCmFPX format. |
| ROCmFP4 | `Q4_0_ROCMFP4` | Existing ROCmFP4 family | Promoted 4-bit ROCm-family baseline inherited by this fork. |
| ROCmFP6 | `Q6_0_ROCMFPX` | 32 weights, packed 6-bit codes, two UE4M3 scales | Middle quality/size ROCmFPX format. |
| ROCmFP8 | `Q8_0_ROCMFPX` | 32 signed 8-bit codes, one UE4M3 scale | High-quality ROCmFPX reference format. |

Common design constraints:

- 32-weight blocks so CPU, HIP, and Vulkan kernels can share Q-style reduction
  assumptions.
- finite unsigned UE4M3 scale bytes.
- explicit integer-code-times-decoded-scale dequant math.
- reconstruction-MSE scale selection where low-bit coherency needs it.
- tensor-aware routing instead of applying one blunt quant type everywhere.

## Build Targets In This Repo

ROCmFPX builds through `containers/Containerfile.rocmfpx`:

| Local backend | Image tag | Compiled backends and userspace |
| --- | --- | --- |
| `vulkan-fpx` | `localhost/strix-llama:vulkan-fpx` | Vulkan/RADV only; ROCm-independent Mesa userspace. |
| `rocm-fpx` | `localhost/strix-llama:rocm-fpx` | HIP plus Vulkan/RADV; stable ROCm userspace. |
| `rocm-next-fpx` | `localhost/strix-llama:rocm-next-fpx` | HIP plus Vulkan/RADV; separate nightly ROCm userspace. |

The fork is pinned in `bin/build.sh` with `ROCMFPX_LLAMA_REF`. Update the pin
only for deliberate testing because the fork is moving quickly.

### Pinned Experimental Branch

The experimental branch reviewed here is pinned at
`a6a93765f7ce9779c13f9881164a65f7a9f31198`. Test it without changing normal
FPX defaults:

```bash
ROCMFPX_LLAMA_BRANCH=experimental-rocmfpx-branch \
ROCMFPX_LLAMA_REF=a6a93765f7ce9779c13f9881164a65f7a9f31198 \
CPU_TARGET=strix-halo \
bin/build.sh rocm-fpx
```

This matches the branch's known-good gfx1151 shape: HIP plus Vulkan, forced
HIP MMQ, Release mode, and Strix CPU instructions. `CPU_TARGET=strix-halo` is
reproducible across capable builders; the fork's host-dependent `GGML_NATIVE`
preset remains available through `CPU_TARGET=native`. The branch's winning HIP
decode knobs are source defaults, so leave `ROCMFPX_DECODE_TUNE=stable` unless
running a controlled tuning sweep.

## Quantization Profiles

The fork's `scripts/quantize-rocmfpx-agent.sh` exposes this interface:

```bash
FORMAT=rocmfp8 PROFILE=agent SRC=model-BF16.gguf OUT=model.gguf \
  scripts/quantize-rocmfpx-agent.sh
```

`PROFILE` is a quantization recipe. It maps to a `llama-quantize` preset; it is
not a runtime `llama-server` profile.

| `FORMAT` | `PROFILE` | `llama-quantize` preset |
| --- | --- | --- |
| `rocmfp3` | `straight` | `Q3_0_ROCMFPX` |
| `rocmfp3` | `agent` | `Q3_0_ROCMFPX_AGENT` |
| `rocmfp4` | `straight` | `Q4_0_ROCMFP4` |
| `rocmfp4` | `agent` | `Q4_0_ROCMFP4_COHERENT` |
| `rocmfp6` | `straight` | `Q6_0_ROCMFPX` |
| `rocmfp6` | `agent` | `Q6_0_ROCMFPX_AGENT` |
| `rocmfp6` | `strix-lean` | `Q6_0_ROCMFPX_STRIX_LEAN` |
| `rocmfp6` | `strix-speed` | `Q6_0_ROCMFPX_STRIX_SPEED` |
| `rocmfp6` | `strix-quality` | `Q6_0_ROCMFPX_STRIX_QUALITY` |
| `rocmfp8` | `straight` | `Q8_0_ROCMFPX` |
| `rocmfp8` | `agent` | `Q8_0_ROCMFPX_AGENT` |

The `strix-*` profiles exist only for `FORMAT=rocmfp6`.

## Straight Profiles

`straight` means the baseline ROCmFPX family route for that bit width.

It still has some tensor-aware protection in the fork; "straight" does not
mean every quantizable tensor is forced to exactly the same type. The fork
already routes sensitive tensors differently for Q3 and Q6 because pure low-bit
ROCmFPX passed runtime checks but lost too much instruction-following quality.

Use `straight` for:

- size and speed sweeps;
- low-risk runtime/kernel checks;
- comparing ROCmFPX formats against stock GGUF quants.

Avoid `straight` as the default for JSON/tool/coding/chat-agent use unless a
specific model has been validated under those workloads.

## Agent Profiles

`agent` profiles keep the same ROCmFPX math and kernels but spend more bits on
tensors that tend to break structured behavior:

- token and output embeddings;
- attention Q/K/V/O and fused QKV tensors;
- selected FFN-down tensors;
- selected FFN-gate tensors;
- selected FFN-up tensors for the lower-bit agent routes.

Intent: preserve JSON shape, tool-call shape, coding behavior, and chat
coherency without moving the whole model to a generic high-bit quant.

Practical tradeoff:

- bigger than `straight`;
- usually lower risk for structured output;
- may be slower depending on how much extra precision lands on hot tensors;
- still model- and prompt-sensitive.

The fork's local Qwen3-0.6B dry-run size table showed the direction of the
tradeoff:

| Preset | Size/BPW from fork docs | Note |
| --- | --- | --- |
| `Q3_K_M` | 325.37 MiB / 4.58 BPW | Stock baseline in that sweep. |
| `Q3_0_ROCMFPX` | 330.57 MiB / 4.65 BPW | Similar size to Q3_K_M after lean routing. |
| `Q3_0_ROCMFPX_AGENT` | 437.62 MiB / 6.16 BPW | Much larger to protect agent behavior. |
| `Q6_K` | 466.50 MiB / 6.57 BPW | Stock baseline in that sweep. |
| `Q6_0_ROCMFPX` | 466.65 MiB / 6.57 BPW | Nearly same size as Q6_K. |
| `Q6_0_ROCMFPX_AGENT` | 541.76 MiB / 7.62 BPW | Larger, agent-protected. |
| `Q8_0` | 604.15 MiB / 8.50 BPW | Stock baseline in that sweep. |
| `Q8_0_ROCMFPX` | 586.39 MiB / 8.25 BPW | Smaller than stock Q8_0 in that sweep. |
| `Q8_0_ROCMFPX_AGENT` | 598.90 MiB / 8.43 BPW | Still below stock Q8_0 in that sweep. |

These numbers came from the fork's local Qwen3-0.6B dry-run source, so treat
them as directional, not universal.

## Strix Profiles

The `strix-*` profiles are Strix Halo-oriented `rocmfp6` recipes. They are
hybrid tensor mixes designed to explore speed/quality points around FP4-fast
bulk tensors and FP6/FP8 protected tensors.

### `strix-speed`

Preset: `Q6_0_ROCMFPX_STRIX_SPEED`

Routing intent:

- bulk transformer tensors use `Q4_0_ROCMFP4_FAST`;
- token/output tensors use `Q6_0_ROCMFPX`;
- attention Q/K/V/O use `Q6_0_ROCMFPX`;
- selected FFN down/gate protection from `strix-lean` is omitted.

Use when:

- FP4-fast bulk speed matters most;
- `strix-lean` is still too slow;
- workload can tolerate more quality/coherency risk.

Expected tradeoff: fastest Strix ROCmFPX profile, riskiest quality floor.

### `strix-lean`

Preset: `Q6_0_ROCMFPX_STRIX_LEAN`

Routing intent:

- bulk transformer tensors use `Q4_0_ROCMFP4_FAST`;
- token/output tensors use `Q6_0_ROCMFPX`;
- attention Q/K/V/O and fused QKV use `Q6_0_ROCMFPX`;
- selected FFN-down and FFN-gate layers use `Q6_0_ROCMFPX`.

Use when:

- `strix-speed` is too fragile;
- you still want to stay closer to FP4 speed/size than a mostly-FP6 model;
- you need a middle point for Strix Halo tests.

Expected tradeoff: middle profile. More protection than `strix-speed`, less
bulk precision than `strix-quality`.

### `strix-quality`

Preset: `Q6_0_ROCMFPX_STRIX_QUALITY`

Routing intent:

- bulk transformer tensors use `Q6_0_ROCMFPX`;
- token/output tensors use `Q8_0_ROCMFPX`;
- attention Q/K/V/O and fused QKV use `Q8_0_ROCMFPX`;
- selected FFN-down and FFN-gate layers use `Q8_0_ROCMFPX`.

Use when:

- FP4-fast Strix recipes fall below a quality floor;
- agent/coding/JSON behavior matters more than size/speed;
- you want a high-quality Strix comparison point before jumping to full
  `Q8_0_ROCMFPX` or `Q8_0_ROCMFPX_AGENT`.

Expected tradeoff: largest/slowest Strix profile, strongest quality floor among
the three Strix recipes.

## Choosing A Profile

Local decision guide:

| Goal | First profile to test | Why |
| --- | --- | --- |
| Minimal size/speed exploration | `straight` | Least protected family route. |
| General coding-agent use | `agent` | Protects structured-output-sensitive tensors. |
| Strix speed probe | `FORMAT=rocmfp6 PROFILE=strix-speed` | FP4-fast bulk, FP6 attention/output only. |
| Strix balanced probe | `FORMAT=rocmfp6 PROFILE=strix-lean` | FP4-fast bulk plus selected FP6 FFN protection. |
| Strix quality probe | `FORMAT=rocmfp6 PROFILE=strix-quality` | FP6 bulk plus FP8 protected tensors. |
| Conservative high-quality agent quant | `FORMAT=rocmfp8 PROFILE=agent` | Highest agent-protected ROCmFPX route exposed by the wrapper. |

For the experimental branch, start with `Q4_0_ROCMFP4_FAST` when decode speed
and size dominate, `Q4_0_ROCMFP4_COHERENT` or another `*_AGENT` preset for
tools/JSON/code, and `Q4_0_ROCMFP4_STRIX_LEAN` for the branch's balanced
gfx1151 recipe. Create quality-test quants from BF16 or F16 sources and compare
against that source; requantized GGUFs are suitable only for smoke tests.

For this repository's runtime configs, the most relevant existing downloaded
models are already quantized. Generated model presets do not choose these
profiles; they only detect ROCmFPX/ROCmFP4-compatible model files and route
them to the `*-fpx` images.

## Runtime Notes

Quantization profile and runtime backend are independent:

- quantization chooses tensor types in the GGUF file;
- `vulkan-fpx`, `rocm-fpx`, and `rocm-next-fpx` choose the runtime image;
- K/V cache type remains a separate runtime setting.

The fork also includes TurboQuant K/V cache paths such as `turbo3` and
`turbo4`. Those are not ROCmFPX model-weight quantization profiles. The fork's
docs recommend asymmetric K/V for agentic serving experiments: preserve K cache
at a safer type and compress V more aggressively.

On the pinned branch, the safe asymmetric starting point is `-ctk q8_0 -ctv
turbo4`. Symmetric TurboQuant remains an experiment, not the agent-serving
default.

For MTP/NextN models, the branch recommends Vulkan decode for measured Strix
Halo performance and enables speculative decoding for both dense and MoE:

```bash
bin/run.sh rocm-fpx cli /path/to/model.gguf \
  -dev Vulkan0 -ngl 999 -fa 1 --no-mmap \
  --spec-type draft-mtp --spec-draft-n-max 6 --spec-draft-p-min 0.6
```

`-fa 1` and `--no-mmap` remain mandatory local Strix Halo defaults. MTP gains
are content-dependent; the target model verifies drafts, and M-RoPE MTP fixes
in this branch prevent silent fallback on Qwen3.5/Qwen3.6 architectures.

This repo's generated ROCmFPX-compatible presets currently keep K/V cache at
`f16` for the author-profiled ROCmFPX routes. Do not infer a model-weight
profile from K/V cache settings.

## Caveats

- ROCmFPX is experimental research code.
- Profile behavior is model-, prompt-, backend-, and driver-sensitive.
- Use BF16/F16/F32 sources for meaningful quality quants; re-quantizing already
  quantized GGUFs is useful for smoke tests, not final quality.
- `IMATRIX` can be passed through the wrapper; low-bit formats benefit from
  importance data when available.
- The `strix-*` names are quantization presets, not build-time
  `ROCMFPX_DECODE_TUNE` launch-geometry profiles. `ROCMFPX_DECODE_TUNE` changes
  HIP kernel launch tuning at build time; `PROFILE=strix-*` changes model tensor
  routing at quantization time.
