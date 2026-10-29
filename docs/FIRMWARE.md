# Q6A boot firmware (SPI "BIOS"): status and what it means for us

Checked 2026-10-29 against:

- Radxa's docs (SPI firmware, boot, EDL mode, downloads)
- the forum thread "Radxa Dragon Q6A firmware snapshot" (posts up to 2026-10-28)
- the firmware packages themselves (memory maps read from the images)

## 1. Releases

| Release | Package | Base | Highlights | Notes |
|---|---|---|---|---|
| 2025-09-29 | `250929` | Qualcomm Linux (`qualcomm-linux-spf-1-0`) | Factory firmware | Embedded DTB not loaded properly. Superseded. |
| 2025-10-13 | `dragon-q6a_flat_build_251013.zip` | Qualcomm Linux | Fixed boot order **USB > SD > NVMe > eMMC > UFS > USB**; UiApp (UART only); embedded DTB for 6.17 | Last Linux-only base. Not compatible with RadxaOS R1+ images (they need ≥ 20251230) |
| 2026-01-20 | `dragon-q6a_flat_build_wp_260120.zip` | **`qcm6490-wp-1-0`** (Windows + Linux) | **HDMI in UEFI setup**, PXE/HTTP boot, GPIO config, **configurable boot order**, **persistent UEFI variables readable from Linux**, DTB auto-pick for kernels 6.17/6.18 | Third-party OSes must carry Radxa's `linux-6.18.2` kernel patches and `alsa-ucm-conf` patches. Kernels from before those patches lose SPI flash access. |
| **2026-09-16** (posted 2026-10-28) | **`dragon-q6a_flat_build_wp_260916.zip`** | `qcm6490-wp-1-0` | **Fixes booting UKI / systemd-stub kernels**, **improved PCIe detection**, **reboot to UEFI setup from Linux**, UFS stability, USB compatibility, I2C RTC in UEFI, custom boot logo | **Latest.** Radxa's download page still lists 260120; the file is at `https://dl.radxa.com/dragon/q6a/images/dragon-q6a_flat_build_wp_260916.zip` (10,732,405 bytes, sha256 `f736fdd6744cbbcce6d5b76feb813d6cd02593493b3a1213e8b3c7deb1f9d1fc` as downloaded) |

Other facts gathered:

- UEFI setup opens with **F2** at power-on on the `wp` firmware, now with HDMI output.
- **Gunyah** is the hypervisor and Linux runs at EL1, so **KVM is not available**. That doesn't affect us: FEX doesn't need KVM.
- MIPI DSI displays aren't supported in UEFI. Irrelevant for us; we use HDMI.

## 2. The memory cost of the `wp` firmware

A forum user reported losing about 0.5 GB of RAM after updating. The memory maps inside the two packages back that up:

| Region (firmware-reserved, not usable by Linux) | 251013 (Linux base) | 260916 (`wp` base) |
|---|---|---|
| **PIL Reserved** (co-processor firmware) | 87 MiB | **378 MiB** |
| Display Reserved (UEFI framebuffer) | — | 36 MiB |
| LPASS_ML / CDSP | 30 MiB (CDSP) | 15 MiB (LPASS_ML) |
| WLAN FW, ADSP RPC, MPSS_EFS, misc. | ~25 MiB | ~35 MiB |
| **Total marked reserved** | **~142 MiB** | **~464 MiB** |

- On 251013, "PIL Reserved" exactly covers the co-processors the Q6A uses: ADSP 40 + CDSP 30 + video 7 + CVP 5 + camera 5 MiB.
- The `wp` map sizes it for a Windows platform with a **modem and a Wi-Fi co-processor**, which the Q6A doesn't have; Radxa's own Linux device tree deletes those regions.
- So **about 320 MiB of the 8 GB board's RAM is reserved for hardware that isn't there.** Linux can't reclaim memory that the UEFI memory map marks reserved, so DT changes don't help.

These totals come from the firmware's static memory-map tables. The real figure is `MemTotal` on the board, and Phase 0 measures it on both firmwares.

## 3. Recommendation

**Use 260916**, because it fixes things we depend on:

- **UKI / systemd-stub boot:** our planned boot path
- **better PCIe detection:** NVMe boot
- **reboot to firmware setup**
- **persistent EFI variables**
- an HDMI setup menu and configurable boot order

At the same time:

1. **Ask Radxa for a Linux-sized memory map**, either a firmware build or a setup option that reserves PIL space only for ADSP/CDSP/video. That would give the ~320 MiB back. Post on the firmware thread with the memory-map comparison above; the case is clear and easy for them to verify.
2. **Phase 0 measures `MemTotal` on 260916 and 251013.** If Radxa doesn't trim the map and the measured difference is large, 251013 is a fallback for the 8 GB board: it boots NVMe through its fixed order, and we ship our own DTB anyway. Its costs: no UKI fix (Type 1 boot entries still work), no HDMI setup menu, no EFI variables. Flashing between firmwares is safe because EDL recovery is in ROM (§5).
3. **Patching the memory map in `xbl.elf` ourselves** is technically possible: the table is stored uncompressed, and EDL makes it recoverable. But the hypervisor and TrustZone may rely on that layout. Research only, not for users.

## 4. Consequences for our OS design

| Firmware fact | Impact |
|---|---|
| Auto-DTB only knows kernels 6.17/6.18 | **We always supply our own DTB**, embedded in the UKI or via a `devicetree` line in the systemd-boot entry. Never rely on the firmware's. |
| UKI boot fixed in 260916 | Boot entries become **UKIs** (kernel + initramfs + DTB + cmdline in one signed-able file per slot). Type 1 entries stay as the fallback for older firmware. |
| Persistent EFI variables need kernel support | Mainline's Qualcomm EFI-variable allowlist (`qcom_scm_qseecom_allowlist` in `drivers/firmware/qcom/qcom_scm.c`) **doesn't include `radxa,dragon-q6a`**. Armbian's 7.2 kernel already carries this (`0018-firmware-qcom-scm-Allow-QSEECOM-for-Radxa-Dragon-Q6A.patch`), so we take theirs. Without it, `bootctl` set-default/one-shot and reboot-to-setup won't work. |
| Boot counting / A/B | systemd-boot boot counting works by **renaming files on the ESP**, so it doesn't depend on EFI variables. That keeps A/B rollback independent of the patch above. |
| Radxa: third-party kernels need the `linux-6.18.2` patch set for the `wp` firmware | Armbian's 7.2 set already covers EFI variables and SPI flash access (§7). Kernel task: diff Radxa's `linux-6.18.2` branch against Armbian's 20 patches and carry anything else that's missing. |
| Audio needs Radxa's `alsa-ucm-conf` patches on the `wp` firmware | Part of our UCM profile for the headset jack and HDMI ([ROADMAP.md](ROADMAP.md) v1 must-haves) |
| Reboot to UEFI setup | Add a "Reboot to firmware setup" item in Desktop Mode and in Steam's power menu (`systemctl reboot --firmware-setup`) once EFI variables work |
| Configurable boot order | The installer doesn't touch it. The docs recommend leaving USB first so a recovery stick always works. |

## 5. Updating the firmware safely

Our OS **never flashes firmware automatically**. It checks the installed version (via SMBIOS/DMI: confirm in Phase 0 which field carries the release date) against `SPI_FW_MIN` in `versions.env` and shows a notice with instructions.

**Recommended method: from a host computer in EDL mode.** Some users have reported unbootable boards after the on-device method.

1. Hold the **EDL button** with the board unpowered, connect 12 V USB-C PD power, then release.
2. Connect the Q6A's **USB 3 Type-A port** to the host with a **USB A-to-A** cable. A forum user confirmed a data-capable **A-to-C** cable also works.
3. Check `lsusb` shows `05c6:9008`.
4. In `flat_build/spinor/dragon-q6a/` from the firmware zip, run:
   ```
   sudo edl-ng --memory spinor --loader prog_firehose_ddr.elf rawprogram rawprogram0.xml patch0.xml
   ```
   (`edl-ng` v1.6.0 from github.com/strongtz/edl-ng)
5. Re-plug the power, or run `edl-ng reset`.

On-device alternative (Radxa's documented method, needs a kernel with SPI-NOR MTD access):

```
sudo edl-ng --hostdev-as-target /dev/mtd0 rawprogram rawprogram0.xml patch0.xml
```

**Recovery:** the board's ROM bootloader (PBL) always offers EDL, so a bad flash can be fixed with the host method. Don't run Radxa's documented `erase-part` commands unless you intend to reflash immediately.

## 6. Tasks this adds

- Phase 0: flash 260916; record `MemTotal`, DMI/SMBIOS version fields, NVMe detection and the F2 setup menu over HDMI. Repeat `MemTotal` on 251013.
- Post the memory-map request to Radxa (§3).
- Kernel: add `radxa,dragon-q6a` to `qcom_scm_qseecom_allowlist`; diff Radxa's `linux-6.18.2` patches against our set.
- Boot: UKI per slot with an embedded DTB; Type 1 fallback.
- `versions.env`: `SPI_FW_RECOMMENDED=wp_260916`, `SPI_FW_MIN` (set after Phase 0). The watcher polls the forum thread's JSON (`https://forum.radxa.com/t/28886.json`) and Radxa's download page for new releases and opens an issue. It never auto-flashes.

## 7. Armbian findings

From `armbian/build` at `f5caa93` (2026-10-29), the Armbian board page, and Armbian's apt repository:

**Kernels.** `config/sources/families/qcs6490.conf` defines two:

| Branch | Source | Notes |
|---|---|---|
| `current` | Radxa's vendor tree, `radxa/kernel` branch `linux-6.18.2` | What the board page offers (6.18.2), plus 2 small patches |
| `edge` | **mainline tag `v7.2.3`** + 20 patches in `patch/kernel/archive/qcs6490-7.2/` | Our base: same major version as Valve's `linux-72-deckard` |

The 20 `edge` patches cover:

- **DTS:** UFS, USB 3, ICE, custom CDSP firmware path, QSPI node removal
- **Display (`drm/msm` DP/DPU):** audio prepare when DP is inactive, core-clock reassert on resume, stale DSC cleanup, DP parity fix, skip `push_idle` when inactive, missing `drm_edid_connector_update`, DSPP reservation cap, **HPD replug handling**
- **UFS:** HS-G4 PHY table fix, RPMB bus registration
- **Video:** Iris firmware error messages
- **Firmware access:**
  - `0016` / `0017` / `0020`: SCM storage interface and MTD driver. On the `wp` firmware, the **SPI NOR is owned by TrustZone** and Linux can only reach it through this `qcom_scm_storage` MTD device. That's why older kernels lost firmware-update access.
  - `0018`: **QSEECOM allowlist entry for the Q6A**, for EFI variables (§4)

**Board config** (`config/boards/radxa-dragon-q6a.conf`):

- Boots with **GRUB plus an explicit DTB** (`grub-with-dtb` extension, `qcom/qcs6490-radxa-dragon-q6a.dtb`). Armbian doesn't rely on the firmware's DTB either.
- Adds GPU, GMU, QUP, ADSP/CDSP and **audio topology** (`qcom/qcs6490/QCS6490-Radxa-Dragon-Q6A-tplg.bin`) firmware to the initramfs. We copy this list.
- Installs Radxa's `alsa-ucm-conf` backport `1.2.16.1-radxa-1`, which has the Q6A sound-card UCM plus a DMI matcher that isn't upstream. That's the audio piece we need.
- Wi-Fi/BT via the `radxa-aic8800` extension (USB variant)

**Firmware package.** Armbian ships Radxa's `edk2-qcs6490` package (`edk2-qualcomm` source, version **0.1.0-9**, apt `trixie-utils`).

- It contains exactly the **260916** firmware: `xbl.elf` sha256 `a1b0e8c5…3bf1`, identical to the zip.
- Changelog version string: **`6.0.260916.BOOT.MXF.1.0.1-00549-KODIAKWP-1`**. That's what our firmware check should compare against (Phase 0: confirm it appears in SMBIOS/DMI).

**Two on-device updaters, and only one is safe:**

| Updater | Behaviour | Verdict |
|---|---|---|
| Radxa's `setup.sh` (in the package) | `flash_erase` of the **whole** SPI NOR, then write. No backup, no verification. | Don't use. A failure mid-write leaves nothing bootable. |
| Armbian's `write_uboot_platform_mtd` (BSP, via `armbian-install`) | Finds the `qcom_scm_storage` MTD, **backs up the full NOR to `/var/backups`**, writes, then **reads back and verifies every image** | A good model for any on-device updater we offer later |

Host-side EDL flashing (§5) remains our documented method.

## 8. Qualcomm official documentation

From Qualcomm's Dragonwing docs (Qualcomm Linux 2.1.1, where QCS6490 is the RB3 Gen 2 platform):

- **Kernel tracks:** an LTS track on **v6.18.x** (production default) and a mainline track (`linux-qcom-next`). Qualcomm's direction is upstream-first, so mainline + Armbian patches is a supported-style path, not a hack.
- **Boot:** PBL → XBL → UEFI → **systemd-boot** → kernel as an EFI stub. No GRUB. In production, kernels ship **only as Type 2 UKIs** in `EFI/Linux/`, and `loader.conf` uses `default @saved` (an EFI variable). This matches our UKI-per-slot plan. We use boot counting rather than `@saved`, so A/B doesn't depend on EFI variables.
- **DTB selection:** on Qualcomm's own boards, UEFI picks a DTB from a FIT image in a `dtb_a` partition using SoC/board/DDR IDs. Radxa instead embeds DTBs in its UEFI (kernels 6.17/6.18 only). Either way, we supply ours in the UKI.
- **Hypervisor:** QCS6490's default boot mode is **Gunyah** (Linux at EL1). Qualcomm documents a KVM/EL2 mode for RB3 Gen 2 via `xbl_config_kvm.elf`. On the Q6A that would need a Radxa-built variant; it's a performance research item ([PERFORMANCE.md §7](PERFORMANCE.md#research-boot-linux-at-el2-instead-of-under-gunyah)).
- **Memory:** carve-outs are `no-map` `reserved-memory` nodes in `kodiak.dtsi`. CMA is **reusable by the kernel for movable allocations when idle**, so a large CMA doesn't waste RAM the way carve-outs do. zram is Qualcomm's documented swap approach.
- **DVFS:** CPU governor default is `performance` on Qualcomm Linux. **L3/LLCC/DDR frequencies follow a static CPU-OPP map** (`opp-peak-kBps` in the CPU OPP tables) plus the **BWMON** governor (`icc-bwmon`). These are the documented knobs for our Performance profiles.
- **Display:** QCS6490 DisplayPort is rated **3840×2160 at 30 fps** (two lanes at HBR3, single stream). The Q6A's HDMI is fed from that DP output through the RA620 bridge, so **expect 4K30 max**. 1080p120 fits; 1440p120 and 4K60 don't. Qualcomm's own RB3 Gen 2 uses a different HDMI path (DSI → Lontium LT9611UXC), so its HDMI debug guide doesn't apply to the Q6A.
- **Proprietary GPU driver:** Qualcomm's Adreno userspace runs on **KGSL**, now an out-of-tree module (`github.com/qualcomm-linux/kgsl`) that works with the upstream DT. But it exposes only **Vulkan 1.1 and OpenGL ES**. It can't run DXVK/VKD3D-Proton (Vulkan 1.3), desktop-GL games or FEX's x86 driver slices, so Turnip stays our only driver ([UPDATES.md §3](UPDATES.md#3-gpu-driver-channels)).
- **Paywalled detail:** Qualcomm's QCS6490 performance and power addenda (CPU/GPU tunables, KPIs) link to `docs.qualcomm.com` pages for licensed users only. We can't use them.

### Sources

- Armbian build: `config/boards/radxa-dragon-q6a.conf`, `config/sources/families/qcs6490.conf`, `patch/kernel/archive/qcs6490-7.2/` at https://github.com/armbian/build
- Armbian board page: https://www.armbian.com/radxa-dragon-q6a/
- Armbian apt: `https://apt.armbian.com/pool/trixie-utils/e/edk2-qualcomm/edk2-qcs6490_0.1.0-9_all.deb`
- Qualcomm docs index: https://dragonwingdocs.qualcomm.com/llms.txt. Pages used:
  - `System/Kernel/supported-versions-and-compatibility`
  - `System/Kernel/boot-flow-and-architecture-overview`
  - `System/Kernel/uefi-and-systemd-boot`
  - `System/Kernel/efi-stub-and-boot-partitions`
  - `System/Kernel/device-tree-architecture`
  - `System/Kernel/enable-virtualization`
  - `System/Kernel/configure-and-manage-memory`
  - `System/Kernel/configure-the-dynamic-voltage-and-frequency-scaling-dvfs-governors`
  - `Technologies/Graphics/graphics-overview`
  - `Technologies/Display/display-specs-qcs6490`
  - `Technologies/Display/troubleshoot-debug-hdmi-qcs6490`
- Radxa firmware thread (posts to 2026-10-28): https://forum.radxa.com/t/radxa-dragon-q6a-firmware-snapshot/28886
