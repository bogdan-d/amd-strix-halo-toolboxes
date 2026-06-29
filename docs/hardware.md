# Hardware, Host Configuration & VRAM

Strix Halo (gfx1151) is an APU with **unified memory**: system RAM is shared with
the iGPU, so up to ~124 GiB can act as GPU memory for large models. Getting there
requires a working kernel/firmware stack and the right boot parameters. This page
collects the host-side setup, firmware troubleshooting, and VRAM planning.

## Stable configuration

- **OS**: Fedora 42/43
- **Linux kernel**: 6.18.9-200.fc43.x86_64
- **Linux firmware**: 20260110

Kernels older than **6.18.4** have a gfx1151 stability bug and should be avoided.
**Do NOT use `linux-firmware-20251125`** — it breaks ROCm on Strix Halo
(instability/crashes). See [Firmware](#firmware) to check and downgrade.

## Kernel parameters

These boot parameters hand unified memory to the iGPU while reserving at least
4 GiB for the OS (up to 124 GiB for the iGPU):

```
amd_iommu=off amdgpu.gttsize=126976 ttm.pages_limit=32505856
```

| Parameter                  | Purpose                                                                        |
|----------------------------|--------------------------------------------------------------------------------|
| `amd_iommu=off`            | Disables the AMD IOMMU. Measured 5–12% faster and more stable than `iommu=pt`. |
| `amdgpu.gttsize=126976`    | Caps GPU unified memory at 124 GiB (126976 MiB ÷ 1024).                        |
| `ttm.pages_limit=32505856` | Caps pinned memory at 124 GiB (32505856 × 4 KiB = 126976 MiB = 124 GiB).       |

Apply on Fedora:

```bash
sudo grub2-mkconfig -o /boot/grub2/grub.cfg
sudo reboot
```

### Ubuntu 24.04

See [TechnigmaAI's GTT memory step-by-step guide](https://github.com/technigmaai/technigmaai-wiki/wiki/AMD-Ryzen-AI-Max--395:-GTT--Memory-Step%E2%80%90by%E2%80%90Step-Instructions-%28Ubuntu-24.04%29).

## Firmware

### Check your version

```bash
rpm -qa | grep linux-firmware
```

If you see `linux-firmware-20251125`, **you must downgrade** — that build breaks
ROCm on Strix Halo. The recommended stable version is `20251111`.

### Downgrade (Fedora)

```bash
mkdir -p ~/linux-firmware-downgrade
cd ~/linux-firmware-downgrade

# Fedora 43:
wget -r -np -nd -A '*.rpm' https://kojipkgs.fedoraproject.org/packages/linux-firmware/20251111/1.fc43/noarch/
# (Fedora 42: replace fc43 with fc42 in the URL above)

sudo dnf downgrade ./*.rpm
sudo dracut -f
```

**`dracut -f` regenerates the initramfs for the *currently running* kernel.** If
you are not running the kernel you intend to boot, specify it explicitly:

```bash
sudo dracut -f --kver 6.18.4-200.fc43.x86_64
```

Then reboot:

```bash
shutdown -r now
```

## VRAM planning

It is not enough to check model file size: context length and runtime overheads
dominate memory use on Strix Halo. Use the bundled estimator to read a `.gguf`
and print the estimated VRAM for given context sizes.

The estimator is built into every image at `/usr/local/bin/gguf-vram-estimator.py`
and is also checked in on the host at `scripts/gguf-vram-estimator.py`.

```bash
# on the host:
python3 scripts/gguf-vram-estimator.py models/my-model.gguf --contexts 32768 131072

# or inside a running container:
bin/run.sh rocm run gguf-vram-estimator.py /models/my-model.gguf --contexts 32768
```

It handles single- and multi-shard GGUFs. Example (Qwen3-235B Q3_K, high context):

```
Context Size | Context Memory | Est. Total VRAM
    65,536   |    11.75 GiB   |    110.75 GiB
   131,072   |    23.50 GiB   |    122.50 GiB
   262,144   |    47.00 GiB   |    146.00 GiB
```

> "Est. Total VRAM" is model + context only. It does **not** include the OS,
> other processes, or container overhead — always leave a margin. For very large
> contexts, prompt-processing speed is usually the real bottleneck.

## Test configuration

| Component        | Specification                                   |
|:-----------------|:------------------------------------------------|
| **Test machine** | Framework Desktop                               |
| **CPU**          | Ryzen AI MAX+ 395 "Strix Halo"                  |
| **System memory**| 128 GB RAM                                      |
| **GPU memory**   | 512 MB allocated in BIOS                        |
| **Host OS**      | Fedora 43, Linux 6.18.5-200.fc43.x86_64         |

## References

- [Strix Halo Home Lab (deseven)](https://strixhalo-homelab.d7.wtf/) — hardware database and host-config notes.
- [Strix Halo Testing Builds (lhl)](https://github.com/lhl/strix-halo-testing/tree/main).
- [ROCmFP4/TheRock memory-cap issue](https://github.com/ROCm/TheRock/issues/4645) — affects `rocm-next`/`rocm7-nightlies` builds (64 GB cap).
