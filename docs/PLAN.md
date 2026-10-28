# SteamOS (Steam Frame build) on the Radxa Dragon Q6A: feasibility and plan

Status: research and planning, October 2026. Nothing has been built yet.

## TL;DR

**Yes, it's feasible.** The pieces needed already exist, though nobody has put them together for this board:

1. **Valve's Steam Frame SteamOS is a generic aarch64 userspace.** It downloads from Valve's public CDN as a signed RAUC bundle plus casync chunk store. Community projects already run it on non-Frame Snapdragon chips (SM8250, SM8550, SM8650, SM8750) with their own kernels.
2. **The Q6A (QCS6490 / "kodiak") is supported in mainline Linux.** The board DTS is upstream. Armbian merged a mainline 7.1 target in July 2026 with HDMI, USB3, UFS, Wi-Fi/BT and DSP working. The Adreno 643 runs on Mesa Turnip, which is the same Vulkan driver Valve ships for the Frame.
3. **The Q6A boots like a PC.** Radxa's SPI firmware is UEFI (EDK2) and boots an EFI bootloader from NVMe. Handhelds have to replace their Android ABL; we don't.

The parts that need real work:

- Our own kernel. Valve's kernel only covers Frame hardware.
- An update pipeline that follows Valve's releases.
- Switching the session from "headset" to "TV/desktop".
- Overclocking, which is mostly limited to the GPU (see section 7).

**Expect lower performance than a Frame.** The QCS6490 is a mid-range 2021-class chip. Its GPU has roughly a quarter to a third of the Frame's Adreno 750 throughput, and the CPU is 4×A78 + 4×A55 against the Frame's X4/A720 cores. x86 games via FEX + Proton will be limited to lighter and older titles at 720p–1080p. Native ARM64 games, Android apps (Lepton), streaming and Desktop Mode will run well.

---

## 1. What we're porting

| | Steam Frame | Radxa Dragon Q6A |
|---|---|---|
| SoC | Snapdragon 8 Gen 3 (SM8650) | QCS6490 (SC7280 family, "kodiak") |
| CPU | 1×Cortex-X4 + 5×A720 + 2×A520 (Armv9) | 1×A78 @2.7 GHz + 3×A78 @2.4 GHz + 4×A55 @1.96 GHz (Armv8.2) |
| GPU | Adreno 750 | Adreno 643 (812 MHz stock, 900 MHz exists in the upstream OPP table for some bins) |
| RAM | 16 GB LPDDR5X | 4–16 GB LPDDR5 (buy 12 or 16 GB) |
| Storage | UFS | M.2 M-key 2230 NVMe (PCIe 3.0 x2), UFS module, eMMC, microSD |
| Boot | Qualcomm XBL → U-Boot → GRUB, slot control via `splctl` | Qualcomm XBL → **UEFI (EDK2) on SPI NOR** → any EFI loader |
| Display | Internal panels (VR) | HDMI 2.0 via DP→HDMI bridge (RA620) |

What the Frame image contains (from Valve's published sources, mirrored at `evlaV/deckard`):

- **Kernels:** `linux-72-deckard` (7.2, branch `sm8650-7.2`) and `linux-618-deckard`. Frame-only.
- **Mesa:** `deckard-mesa-linux-aarch64`, built with `vulkan-drivers=freedreno` (Turnip), `gallium-drivers=zink` and `-march=armv8.2-a`. It is not restricted to one GPU and the baseline matches our A78/A55 cores. There are also x86_64/i386 slices for FEX guests and an Android slice for Lepton.
- **Session and apps:** gamescope, KDE Plasma (Desktop Mode), FEX, Proton (ARM64EC), Lepton (Android runtime), the native arm64 Steam client.
- **Updates:** `rauc` and `atomupd-daemon`/`steamos-atomupd-client`, with A/B rootfs slots.
- **Frame hardware and VR:** SteamVR session, FPGA/display service, tracking, `deckard-fan-control`, `deckard-uboot-splctl`, `kernelsetup.sh`.

Image source (public, signed by Valve's `CN=steamdeck-images` CA):

```
manifest:  https://steamdeck-atomupd.steamos.cloud/meta/holo/steamos/aarch64/vr/<stable|rc>.json
bundle:    https://steamdeck-images.steamos.cloud/vr/<BUILD>/deckard-<BUILD>-<VER>.raucb
chunks:    https://steamdeck-images.steamos.cloud/vr/<BUILD>/deckard-<BUILD>-<VER>.castr
           https://steamdeck-images.steamos.cloud/vr/chunks.castr
```

The bundle (about 2 MB) contains `manifest.raucm` (`compatible=steamos-aarch64`, rootfs sha256) and `rootfs.img.caibx`. The rootfs (about 10 GB, about 4.4 GB of chunks) is reassembled with `desync`/casync and checked against the signed hash.

### Prior art we build on

- **hashtagbasit/SteamOS-ARM-Handhelds** (GPL-2.0) runs the Frame userspace with ROCKNIX-based kernels on SM8250 through SM8750. Its SM8250 target (Adreno 650, A77, Armv8.2) is the closest relative of our chip. It shows that the Frame userspace runs on Armv8.2 cores and on a6xx-generation Adreno. We can reuse its rootfs extractor, its list of masked Frame services, its Mesa slice build scripts, and its standby, InputPlumber and Decky work.
- **fxgl/steamac** runs the *unmodified* Frame image in a VM on Apple Silicon and downloads it from Valve at install time. Our installer follows the same model, so we never redistribute Valve's image.
- **Armbian `qcs6490-7.1` patches** (PR #10162) add HDMI, DP/DPU fixes, UFS, USB3 and DSP firmware paths for the Q6A on mainline 7.1.

---

## 2. Feature parity target (everything except VR)

| Frame feature | On Q6A | Notes |
|---|---|---|
| Game Mode (gamescope + Steam Big Picture UI) | ✅ planned | Output over HDMI at 1080p/1440p/4K, using gamescope FSR/NIS upscaling to render below 4K |
| Desktop Mode (KDE Plasma) | ✅ planned | Stock Valve packages |
| Native arm64 Steam client | ✅ | Comes with the image |
| x86/x64 Linux and Windows games (FEX + Proton ARM64EC) | ✅ planned | Works, but slow (see section 9) |
| Android apps and games (Lepton) | ✅ planned | Needs the Android Mesa slice to support A643 (verified in Phase 0) |
| Steam Input, Steam Controller (2026) via USB puck, Xbox/PS/8BitDo pads | ✅ planned | USB and Bluetooth; `hid-steam` in kernel |
| Remote Play / Steam Link streaming | ✅ planned | Hardware video decode through the Iris V4L2 driver |
| Cloud saves, store, friends, Discover/Flatpak | ✅ | Userspace only |
| Decky Loader plugins | ✅ planned | Also hosts our tuning plugin |
| Atomic A/B OS updates from the Steam UI | ✅ planned | See section 6 |
| Sleep/wake | ⚠️ best effort | Suspend on SC7280 SBCs is less mature than on handhelds. Fallback: screen-off + freeze, as the community ports do |
| Wi-Fi 6 / BT (AIC8800 USB module) | ✅ planned | Out-of-tree driver, built against our kernel |
| SteamVR, tracking, passthrough, foveated streaming, eye tracking, FPGA display | ❌ out of scope | Masked |

---

## 3. Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│ NVMe (GPT, same partition roles as Valve's layout)                      │
│                                                                         │
│  esp        FAT32   systemd-boot (or Valve GRUB) + slot selector        │
│  efi-A/B    FAT32   OUR kernel Image + initramfs + q6a.dtb, per slot    │
│  rootfs-A/B btrfs   VALVE rootfs, byte-for-byte, read-only              │
│  var-A/B    ext4    per-slot /var (+ /etc overlay upper)                │
│  home       ext4    /home, games, Steam library (grows to fill disk)    │
└─────────────────────────────────────────────────────────────────────────┘

Boot:  SPI UEFI ─► esp/EFI loader ─► picks slot A|B (boot counting)
       ─► efi-X/Image + initramfs + DTB ─► mounts rootfs-X
       ─► systemd-sysext merges our "q6a device layer" over /usr
       ─► Valve's systemd/gamescope-session/Steam
```

The key decision is to **keep Valve's rootfs unmodified and put everything Q6A-specific in a separate device layer**. The layer has four parts:

1. **Kernel + DTB + initramfs**, in the `efi-A/B` partitions.
2. **A `systemd-sysext` image** (`q6a.raw`, a squashfs with `ID=_any` extension-release). It contains:
   - our `/usr/lib/modules/<kver>`
   - Q6A firmware (`qcom/qcs6490/*`, `a660_*`, AIC8800)
   - ALSA UCM for HDMI audio
   - InputPlumber profiles
   - the tuning daemon
   - a RAUC bootloader handler
   - systemd presets
3. **`/etc` drop-ins**, which persist in Valve's `/etc` overlay. These mask the VR/Frame units, switch the default session to plain gamescope-session, and override `/etc/rauc/system.conf`.
4. **Any Valve binary we have to replace**, ideally none. If one is needed (e.g. a patched gamescope), it goes in the sysext rather than into the rootfs.

Why this design:

- **Valve's signed bundle can be installed as-is.** The signature still verifies, and updates arrive at the same time as on real Frames.
- **The layer only changes when our kernel changes**, not on every Valve release.
- **Rollback works**: A/B slots with boot counting, the same as on a Deck or Frame.

Fallback design (used by the handheld ports): unpack Valve's rootfs, bake in kernel and overlays, and re-sign as **our own** RAUC bundle. It's easier to get booting, but every Valve release needs a rebuild from us. We start here if the sysext route hits a blocker (section 6.3), and the CI pipeline in section 6.2 makes the rebuild automatic.

---

## 4. Kernel

**Base:** Valve's `deckard-linux` `sm8650-7.2` tree, from Valve's GPL source tarballs at `holo-packages.steamos.cloud/archlinux-deckard-hotfixes/source/`.

This is mainline 7.2 plus Valve's patches, which is what the userspace was built and tested against: scheduler tweaks, ntsync, and whatever FEX/Proton rely on. On top of it, forward-port the Armbian `qcs6490-7.1` patch set:

- USB3 + DP-lane routing to the RA620 HDMI bridge
- DP voltage-swing cap for the RA620
- DPU clock/DSC/DSPP fixes
- DP audio fix
- UFS PHY init fix
- CDSP firmware path

**Fallback:** a plain mainline 7.1/7.2 kernel with the Armbian patches. If something in userspace turns out to need a Valve kernel patch, we cherry-pick it.

**Config fragment** (`kernel/q6a.config`):

- Platform: `ARCH_QCOM`, SC7280 GCC/GPUCC/DISPCC/VIDEOCC, `DRM_MSM` (+DP, DPU), `QCOM_CPUFREQ_HW`, interconnect/RPMh, `PHY_QCOM_QMP_*`, `PCIE_QCOM`, `BLK_DEV_NVME`, `SCSI_UFS_QCOM`, `R8169`, remoteproc/FastRPC, `VIDEO_QCOM_IRIS`
- Gaming/compat: `NTSYNC`, `HID_STEAM`, `UHID`, `SYSVIPC`, `ARM64_VA_BITS_48` with 4K pages (FEX needs 4K pages), `FTRACE`/`TRACEFS` (mangoapp / steamos-manager need tracefs)
- Updates: btrfs, squashfs + `EROFS` (sysext), overlayfs

Also build:

- The AIC8800 Wi-Fi/BT driver as an out-of-tree module
- `qcs6490-radxa-dragon-q6a.dtb`, plus DT overlays for the overclock profiles (section 7)

Build on `ubuntu-24.04-arm` GitHub runners with GCC ≥ 15. The handheld ports found older GCC produces early-boot crashes on 7.x.

**Firmware.** Upstream `linux-firmware` + `meta-qcom` provide:

- `qcom/a660_sqe.fw`, `qcom/a660_gmu.bin`
- `qcom/qcs6490/a660_zap.mbn`
- `qcom/qcs6490/radxa/dragon-q6a/adsp.mbn`, `cdsp.mbn`
- `qcom/qcm6490/qupv3fw.elf`

The AIC8800 firmware comes from Radxa's packages.

---

## 5. Boot and storage (M.2 NVMe)

1. Flash the current Radxa SPI firmware (≥ the 2025-10-13 release, which brought fixed boot order and the corrected embedded DTB) using `edl-ng` in EDL mode. This is a one-time step.
2. Default UEFI order is USB > SD > NVMe > eMMC > UFS. Leave it as is: with nothing in USB/SD it boots NVMe, and plugging in a USB stick gives a recovery path.
3. **ESP loader:** use systemd-boot with [boot counting](https://systemd.io/AUTOMATIC_BOOT_ASSESSMENT/). Entries look like `steamos-A+3.conf` / `steamos-B+3.conf`, and `systemd-bless-boot` marks a slot good once the session is up. We pass our own DTB with `devicetree` in the entry instead of relying on the UEFI-patched one. Valve's GRUB package is an alternative if we want to stay closer to stock.
4. **Installer:** a small live USB image (Armbian minimal + our script). It:
   - partitions the NVMe
   - fetches Valve's bundle and verifies its CMS signature against Valve's pinned CA
   - assembles the rootfs with `desync`, verifies the sha256, and writes it to both slots
   - writes the device layer, the ESP and the first-boot provisioning (user, hostname)
   - grows `home` to fill the disk

   Valve's image is never redistributed by us. It's downloaded on the user's own machine, the same way steamac does it.

Recommended hardware:

- 12 or 16 GB Q6A
- a 2230 PCIe 3.0 NVMe (DRAM-less is fine; x2 lanes cap at about 2 GB/s anyway)
- the official heatsink plus a fan
- a 30 W+ USB-C PD supply

---

## 6. Updates that follow Valve's releases

### 6.1 Primary path: install Valve's bundles directly

- We ship an override `/etc/rauc/system.conf`:
  - `compatible=steamos-aarch64`, so it accepts Valve's bundles
  - Valve's keyring, unchanged
  - slots defined by our GPT labels
  - `bootloader=custom` pointing at `q6a-rauc-bootloader`, which flips systemd-boot's default entry and resets its boot counter
- atomupd stays on Valve's `aarch64/vr` stable channel, with optional rc. The Steam UI's *Settings → System → Check for updates* works unchanged. A download only fetches changed casync chunks.
- **Neutralise the Frame-specific post-install steps.** `kernelsetup.sh` writes Frame boot partitions; `splctl` writes U-Boot `bootenv`. Both must be no-ops on our system: masked units, with a `/usr/bin` shadow from the sysext if they're called directly. Phase 0 checks exactly what RAUC/atomupd run during install.
- **Post-update health check:** a oneshot after first boot of a new slot confirms the session started. Then `systemd-bless-boot` marks the slot good. If not, the boot counter runs out and the loader falls back to the old slot.
- **Device-layer updates** (our kernel and sysext) come separately. They're a small signed package from our GitHub Releases, staged into the *inactive* `efi-X` and sysext slot together with the next Valve update, or on their own via the same A/B flip.

### 6.2 CI that watches Valve

A scheduled GitHub Actions workflow (hourly) polls `…/aarch64/vr/stable.json` and `rc.json`. When the build ID changes, it:

1. downloads and verifies the new bundle and rootfs
2. boots it in QEMU (aarch64, virtio-gpu) with our device layer for a smoke test: does systemd reach `graphical.target`, are any masked units resurrected, do any new Frame-only units fail
3. diffs the new rootfs's unit list against the last one and opens an issue if Valve added services
4. marks the build "approved" in a small JSON our updater reads. Optionally, devices only accept Valve builds CI has approved, which gives a "delay until tested" setting.

### 6.3 Fallback path: our own re-signed bundles

If direct install proves impossible, the same CI turns each new Valve build into our own signed RAUC bundle with the device layer baked in, and publishes it to our manifest. Possible blockers:

- RAUC hooks embedded in Valve's bundle that we can't neutralise
- atomupd hard-coding Frame partitions
- a needed rootfs file we can't override from a sysext

atomupd is pointed at our endpoint and our CA. The user experience is the same; the delay after a Valve release is the CI time, roughly 30–60 minutes.

---

## 7. Overclocking and performance tuning

What the silicon and firmware allow:

| Knob | Possible? | How |
|---|---|---|
| **GPU clock** | ✅ modest | Upstream `kodiak.dtsi` already has 840 MHz (`TURBO`) and 900 MHz (`TURBO_L1`) OPPs, enabled only for speed bin `0x02`. We read the Q6A's GPU speed-bin fuse and ship DT overlays that add the 840/900 MHz OPPs for it: about +11% over 812 MHz. Above 900 MHz there's no higher RPMh voltage corner, so higher clocks are unlikely to be stable and are not offered by default. The SM8650 port did the same thing to get 903 MHz. |
| **GPU/DDR bandwidth** | ✅ | Raise the GPU OPPs' `opp-peak-kBps` votes and the devfreq floor so DDR doesn't downclock under load |
| **CPU clock above 2.7/2.4/1.96 GHz** | ❌ (research only) | Frequencies come from a lookup table that the Qualcomm boot firmware programs into the EPSS hardware (`qcom-cpufreq-hw`). Linux can't add steps. Changing it means modifying signed XBL/CPUCP firmware with no public source, with real brick risk. Not in scope. |
| **Sustained CPU performance** | ✅ | `performance` governor or raised `scaling_min_freq` per cluster, uclamp boosting for game threads, pinning game threads to the A78 cores (as the handheld ports do) |
| **Thermal limits** | ✅ with cooling | DT overlay that raises passive trip points, plus a fan curve if a PWM fan is fitted. Hardware LMh/EPSS throttling in firmware stays in place as the safety net. |
| **RAM clock / timings** | ❌ | Fixed by XBL DDR training |

User-facing tuning:

- `q6a-tuned`, a daemon with profiles: Silent / Balanced / Performance / **Overclock**. Overclock = 900 MHz GPU + raised trips + all-core floor.
- A Decky plugin in Game Mode's Quick Access menu for profile, GPU max clock, CPU floors and fan curve, plus per-game profiles keyed by Steam app ID.
- The overclock DT overlays are selected per boot entry, so a bad overclock can always be undone by picking the "Safe (stock clocks)" entry in the boot menu.

---

## 8. Phased plan

The phases are sequential. Each has an exit criterion; don't start the next until it's met.

### Phase 0: Feasibility checks (1–2 weeks)

| # | Check | Pass criterion |
|---|---|---|
| 0.1 | Update SPI firmware; boot Armbian `qcs6490` edge (7.1) from NVMe | HDMI, USB3, Ethernet, Wi-Fi up from NVMe |
| 0.2 | `vulkaninfo` / `vkcube` / `vkmark` on upstream Turnip | A643 enumerated, no GPU hangs |
| 0.3 | Download + verify Valve's rootfs (reuse `extract_rootfs.py`) on the Q6A | sha256 matches signed manifest |
| 0.4 | `systemd-nspawn` into Valve's rootfs on the Armbian kernel, bind `/dev/dri`; run Valve's `vulkaninfo`, `FEXInterpreter` on an x86_64 test binary, the Steam client's `--version` | No SIGILL (no Armv9-only code); Valve's Turnip drives A643 |
| 0.5 | Read Valve's `rauc` `system.conf`, `atomupd` config, RAUC bundle hooks, `kernelsetup.sh`, `splctl` call sites | Written list of everything Frame-specific that runs during an update |
| 0.6 | Same for every Frame-only systemd unit (start from the handheld ports' mask list) | Mask list v0 |

**Go/no-go:** if 0.4 shows Valve's Mesa doesn't handle A643, build our own four Mesa slices (aarch64, x86_64, i386, android) from Valve's `deckard-mesa` tree. The handheld project's `build-mesa.sh` shows how. This adds a slow-tier component but doesn't stop the project.

### Phase 1: Kernel and first boot (2–3 weeks)

- Kernel tree (`kernel/`) with the Armbian patches forward-ported onto Valve's 7.2, plus the config fragment and AIC8800 driver
- Image builder (`build/make-image.sh`): GPT layout from section 3, Valve rootfs in both slots, systemd-boot, efi-A/B, sysext v0
- **Exit:** boots from NVMe to a Valve-rootfs text console over HDMI, with network up

### Phase 2: Game Mode and Desktop Mode (2–4 weeks)

- Mask VR/Frame units. Switch the default session to gamescope-session at the HDMI mode with an output resolution selector. Make the Desktop Mode switch and return to Game Mode work.
- Audio: HDMI (DP audio) UCM profile, USB/BT audio through PipeWire
- Input: InputPlumber, `hid-steam`, Bluetooth pairing from the Steam UI, power button (`pmic_pwrkey`) → steamos-powerbuttond
- **Exit:** login to Steam, install and play a native ARM64 game and a Proton/FEX game, switch to Desktop and back

### Phase 3: Full parity (2–4 weeks)

- Lepton/Android, Remote Play / Steam Link with hardware decode, Decky Loader, Discover/Flatpak
- Sleep: try s2idle/deep. Otherwise use the "display off + cgroup freeze + big cores offline" standby the handheld ports use.
- **Exit:** every ✅ row in section 2 checked on hardware

### Phase 4: Updates (2–3 weeks)

- `/etc/rauc/system.conf` override and `q6a-rauc-bootloader`; neutralise `kernelsetup.sh`/`splctl`
- Boot counting + health check + rollback test: deliberately break slot B and confirm it falls back to A
- Device-layer update packages; CI watcher (section 6.2)
- **Exit:** a real Valve update from build N to N+1 applied from the Steam UI, data intact, rollback proven

### Phase 5: Tuning and overclocking (1–2 weeks)

- Read the speed-bin fuse; build OPP and thermal DT overlays; write `q6a-tuned` + the Decky plugin
- Stability matrix: vkmark/glmark2 + 30-minute game loops per profile, logging temperatures and GPU faults
- **Exit:** Overclock profile stable on the test board; Safe boot entry tested

### Phase 6: Release engineering (ongoing)

- USB installer image, docs, issue templates, signed device-layer releases
- Two-tier CI, as in the handheld project:
  - slow tier: kernel, Mesa if needed
  - fast tier: overlays, image, installer

Rough total for one experienced developer: **3–4 months** of part-time work to reach Phase 5.

---

## 9. Risks and unknowns

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Valve's Turnip build lacks or breaks A643 | Low–med | Med | Build Mesa slices ourselves (Phase 0 gate) |
| Valve binaries use Armv9-only instructions | Low (SM8250 port runs) | High | Phase 0.4 check; report to Valve; patch affected binaries via sysext |
| Valve's update path hard-depends on Frame partitions or `splctl` | Medium | Med | Fallback re-signed bundle pipeline (6.3) |
| Valve changes the CDN layout, signing or channel names | Medium over time | Med | CI watcher alerts; installer pins CA + URL patterns in one config |
| Valve stops publishing the vr channel publicly | Low | High | Keep the last good build mirrored privately for personal use |
| HDMI/DP regressions on new kernels | Medium | Med | Pin kernel per release; carry Armbian/Radxa fixes |
| Suspend unreliable | High | Low | Freeze-based standby |
| Thermal throttling without active cooling | High | Med | Require fan for Performance/Overclock profiles |
| Performance too low for many x86 titles | Certain for AAA | User expectation | Document; FEX profiles per game (fast/compat, like the handheld ports); 720p + FSR |
| Legal: redistributing Valve's image | — | High | Never redistribute; installer downloads from Valve and verifies Valve's signature. Unofficial and unaffiliated with Valve. |

---

## 10. Proposed repository layout

```
docs/                  this plan, hardware notes, install guide
kernel/                patches/, q6a.config, build.sh (Valve 7.2 + Armbian qcs6490 patches)
device-layer/          sysext tree: firmware, modules (built), UCM, InputPlumber, units, rauc handler
  etc/                 masks, session defaults, rauc system.conf override
tuning/                q6a-tuned daemon, DT overlays (opp/thermal), decky-q6a-tuning plugin
installer/             live-USB image + install.sh (partition, fetch+verify Valve image, provision)
build/                 make-image.sh, extract_rootfs.py (from hashtagbasit, GPL-2.0), qemu smoke test
.github/workflows/     kernel.yml (slow tier), image.yml (fast tier), valve-watch.yml (hourly)
versions.env           pins: Valve build, kernel ref, Mesa ref (if self-built), firmware ref
```

The license should be GPL-2.0 so we can reuse the handheld project's scripts and kernel work.

---

## Sources

- Valve Frame SteamOS sources (mirror of Valve's GPL source tarballs): https://github.com/evlaV/deckard. Kernel: https://github.com/evlaV/deckard-linux-no-oopsies
- Coverage of the Frame source drop: https://mixed-news.com/en/steam-frame-source-24-repositories-deckard-linux-kernel-mirror/
- Handheld port (Frame userspace on SM8250–SM8750): https://github.com/hashtagbasit/SteamOS-ARM-Handhelds
- How the handheld ports were assembled: https://vr.org/articles/steam-frame-steamos-android-handhelds-rocknix-lepton-2026
- Unmodified Frame image in a VM, download/verify flow: https://github.com/fxgl/steamac
- Frame SteamOS on Quest, "unmodified Valve image + own kernel" approach: https://github.com/continuumxr/frameshift
- Q6A firmware/UEFI and boot order: https://forum.radxa.com/t/radxa-dragon-q6a-firmware-snapshot/28886, https://docs.radxa.com/en/dragon/q6a/low-level-dev/spi-fw
- Q6A mainline bring-up (UEFI → systemd-boot, firmware paths): https://rootcommit.com/2026/board-bring-up-radxa-dragon-q6a-with-mainline-linux-and-yocto/
- Armbian mainline 7.1 Q6A target (HDMI/DP/UFS/USB3 patches): https://github.com/armbian/build/pull/10162
- Q6A HDMI enablement downstream: https://github.com/qualcomm-linux/meta-qcom-3rdparty/pull/50
- Q6A DTS and GPU OPP table: `arch/arm64/boot/dts/qcom/qcs6490-radxa-dragon-q6a.dts`, `kodiak.dtsi` in mainline Linux
- Q6A Turnip/Vulkan results: https://github.com/geerlingguy/sbc-reviews/issues/85, https://sbcwiki.com/news/articles/radxa-dragon-q6a-full-review/
- Steam Frame overview: https://en.wikipedia.org/wiki/Steam_Frame
