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
| Persistent EFI variables need kernel support | Mainline's Qualcomm EFI-variable allowlist (`qcom_scm_qseecom_allowlist` in `drivers/firmware/qcom/qcom_scm.c`) **doesn't include `radxa,dragon-q6a`**. We carry a one-line patch (and upstream it), and compare against Radxa's `linux-6.18.2` patches. Without it, `bootctl` set-default/one-shot and reboot-to-setup won't work. |
| Boot counting / A/B | systemd-boot boot counting works by **renaming files on the ESP**, so it doesn't depend on EFI variables. That keeps A/B rollback independent of the patch above. |
| Radxa: third-party kernels need the `linux-6.18.2` patch set for the `wp` firmware | Kernel task: diff Radxa's `linux-6.18.2` patches against the Armbian `qcs6490-7.1` set we forward-port. Carry whatever's missing: EFI vars, SPI flash access, audio. |
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
