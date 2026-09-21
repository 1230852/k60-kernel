# Redmi K60 (mondrian) kernel — SukiSU-Ultra + KPM + Baseband Guard

Custom **Linux 5.10 GKI-derived** kernel for the **Redmi K60 standard edition
(`mondrian` / POCO F5 Pro, Qualcomm SM8475 Snapdragon 8+ Gen 1)** with:

* **SukiSU-Ultra** root, integrated in-kernel (kprobe hook)
* **KernelPatchModule (KPM)** support enabled (`CONFIG_KPM=y`)
* **Baseband Guard (BBG)** — kernel-level protection of baseband/boot-chain partitions
* **GCC + LLVM/Clang** toolchain
* **AnyKernel3** flashable zip output

| Component | Upstream | How it is obtained |
|---|---|---|
| Kernel source | `MiCode/Xiaomi_Kernel_OpenSource` branch **`mondrian-s-oss`** | fetched by CI (tarball) |
| SukiSU-Ultra | [SukiSU-Ultra/SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra) | fetched by CI, then `scripts/integrate-sukisu.sh` |
| Baseband Guard | [vc-teahouse/Baseband-guard](https://github.com/vc-teahouse/Baseband-guard) | fetched by CI, then `scripts/integrate-bbg.sh` |
| AnyKernel3 | [osm0sis/AnyKernel3](https://github.com/osm0sis/AnyKernel3) | fetched at packaging time |

The kernel source is **not vendored** in this repo. CI pulls it from upstream at build time, so
every input is pinned by branch and each tarball's SHA-256 is printed in the log. This keeps the
repo tiny and auditable.

---

## Design note: why there are no git submodules

The environment this was developed on blocks the git protocol to GitHub (and
`raw.githubusercontent.com`, and most proxies). Plain HTTPS tarballs from
`codeload.github.com` work. Hence: no submodules, no `git clone`, no `setup.sh | bash` —
CI downloads tarballs and the scripts in `scripts/` apply the same modifications
upstream's own scripts would.

## Files

```
.github/workflows/build-k60.yml   CI: fetch -> integrate -> build -> package -> upload
configs/k60-sukisu-kpm.fragment   the only defconfig additions (KSU/KPM/BBG/CFI/LSM)
scripts/integrate-sukisu.sh       SukiSU-Ultra integration (setup.sh's 3 steps, no git)
scripts/integrate-bbg.sh          Baseband-guard integration (setup.sh's 3 steps, no git)
scripts/build-kernel.sh           defconfig merge + assertions + compile
scripts/package-anykernel3.sh     AnyKernel3 zip (device-checked for mondrian)
BBG_BASEBAND_GUARD.md             what BBG does, how it is wired, how to verify it
```

## Building

Trigger the workflow manually (**Actions -> Build K60 kernel -> Run workflow**). Inputs:

| Input | Default | Notes |
|---|---|---|
| `kernel_repo` | `MiCode/Xiaomi_Kernel_OpenSource` | |
| `kernel_branch` | `mondrian-s-oss` | Redmi K60 standard / SM8475 |
| `sukisu_branch` | `main` | |
| `bbg_branch` | `main` | |
| `cfi_mode` | `off` | `off` \| `thin` \| `full` |

Artifacts: `k60-anykernel3-zip`, `k60-kernel-image`, `k60-build-config` (the final `.config`).

To build locally on any Linux box with clang + aarch64 GCC:

```bash
# fetch sources yourself (tarballs), then:
./scripts/integrate-sukisu.sh kernel sukisu main
./scripts/integrate-bbg.sh    kernel bbg
mkdir -p kernel/configs && cp configs/k60-sukisu-kpm.fragment kernel/configs/
./scripts/build-kernel.sh kernel          # -> kernel/out/arch/arm64/boot/Image.gz
./scripts/package-anykernel3.sh kernel    # -> kernel/out/K60-mondrian-SukiSU-KPM.zip
```

## The config that matters

```
CONFIG_KSU=y            # needs KPROBES && EXT4_FS (both already =y in gki_defconfig)
CONFIG_KPM=y            # needs KSU && 64BIT; selects KALLSYMS + KALLSYMS_ALL
CONFIG_BBG=y            # Baseband Guard LSM
CONFIG_LSM="...selinux,baseband_guard..."
# CONFIG_KSU_MANUAL_HOOK is not set    -> GKI-default kprobe hook
# CONFIG_CFI_CLANG is not set          -> see below
```

Two non-obvious requirements, both discovered by reading upstream source rather than guessing:

1. **`CONFIG_LSM` must contain `baseband_guard`.** BBG's `Makefile` has a hard
   `$(error)` gate that aborts the build otherwise. `gki_defconfig` never sets
   `CONFIG_LSM`, so the value would silently come from `security/Kconfig`'s default and
   the build would fail. We set it explicitly in the fragment.
2. **`CONFIG_CFI_CLANG` must be off** for SukiSU's kprobe hooking to work. `gki_defconfig`
   ships it **on** (`+ CONFIG_LTO_CLANG_FULL=y`); the fragment turns it off and drops to thin LTO.

## Toolchain

* **Clang/LLVM 14** as `CC`/`LD`/`AR`/`NM`/… (LLVM binutils)
* **aarch64-linux-gnu GCC** as the target cross-compiler/binutils driver
* `LLVM_IAS=0` — GCC assembler for `.S`, as Qualcomm 5.10 trees expect

## Flashing

The AnyKernel3 zip patches the existing `boot` partition, so **back up your boot image first**.
It is hard-coded for `mondrian` and will abort on a device-check mismatch. If your ROM manages
its own DTBO, remove `dtb/` from the zip before flashing.

## Caveats — please read

1. **Nothing here has been compiled or boot-tested yet.** The machine used to prepare this repo
   (Windows 10 1809 LTSC) cannot host a Linux kernel build, and every bootable Linux image
   source was blocked by its network. **The first CI run is the real test** — expect genuine
   compile errors on a hand-prepared vendor kernel.
2. `BUILD_VENDOR_DLKM=1` in `build.config.msm.mondrian` means many drivers are modules. A
   bootable device may also need matching `vendor_dlkm` modules; the zip currently ships the
   kernel image + DTBs only.
3. `build.sh` merges configs by concatenation + `olddefconfig`, **not** AOSP `merge_config.sh`.
   It then asserts every required symbol survived, and fails loudly otherwise.
4. AOSP `build/build.sh` is deliberately unused: the MiCode tarball keeps the kernel at the tree
   root (no `common/` + `msm-kernel/` split), so `build.config.msm.gki`'s `common/...` paths
   cannot resolve.

## Licensing

Kernel source `GPL-2.0`. SukiSU-Ultra `GPL-2.0` (headers kept under `drivers/kernelsu/`).
Baseband-guard `GPL-2.0` (kept under `security/baseband-guard/`).
