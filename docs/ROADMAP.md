# Roadmap: revised scope and what to do first

This replaces the phase order in [PLAN.md](PLAN.md) §8. The research in PLAN.md, [GAMESCOPE.md](GAMESCOPE.md), [UPDATES.md](UPDATES.md) and [PERFORMANCE.md](PERFORMANCE.md) still applies.

## Revised project definition

> Build a SteamOS distribution for the Radxa Dragon Q6A from Valve's Steam Frame image. Game Mode (gamescope on HDMI) must work out of the box, and every non-VR Frame feature must work as closely as the hardware allows. Builds are produced automatically whenever Valve, Mesa/Turnip, the kernel or firmware change, and are **tested on a real Q6A before any user receives them**.

### v1 must-haves

1. **Gamescope Game Mode on HDMI**, passing acceptance tests G0–G10 ([GAMESCOPE.md §7](GAMESCOPE.md#7-acceptance-tests)).
2. **Non-VR Frame parity:**
   - Desktop Mode
   - FEX + Proton
   - Lepton (Android)
   - Steam Input and controllers
   - Remote Play / Steam Link
   - recording and screenshots
   - Decky
3. **Sound:**
   - HDMI audio (DP audio through the bridge)
   - the **3.5 mm headset jack**: the board has a WCD9380 codec with headphones + mic on Qualcomm's AudioReach DSP. This needs the audio topology firmware and an ALSA UCM profile for the Q6A's sound card.
   - USB audio
   - Bluetooth audio
   - all through PipeWire, with output switching from the Steam UI
4. **Bluetooth** (AIC8800 combo module):
   - pairing from the Steam UI
   - Xbox/PlayStation/8BitDo/Steam controllers
   - A2DP with high-quality codecs where PipeWire supports them
   - Wi-Fi/BT coexistence tuned so controllers don't lag while downloading
   - The 2026 Steam Controller's USB receiver works independently of Bluetooth.
5. **Performance stack** ([PERFORMANCE.md](PERFORMANCE.md)):
   - upscaling: SGSR/FSR/NIS in gamescope, plus in-game FSR and OptiScaler
   - opt-in frame generation
   - 120 Hz HDMI modes with even frame caps (40 fps at 120 Hz)
   - driver channels and per-game driver presets
   - FEX/Proton per-game profiles
   - pinning game threads to the big cores
6. **Overclocking and thermal control:**
   - GPU 840/900 MHz profiles, plus experimental clocks gated by an on-board stability test with automatic revert
   - fan curve
   - raised thermal limits
   - Silent/Balanced/Performance/Overclock profiles in the QAM
   - per-game profiles
7. **Install to M.2 NVMe**, with A/B updates and automatic rollback, triggered from Steam's own "Check for updates".
8. **An automated update pipeline** for four kinds of upstream: Valve OS builds (including Valve's Mesa and gamescope), Mesa/Turnip (stable and main), the kernel, and firmware. It includes hardware-in-the-loop testing and release channels ([UPDATES.md](UPDATES.md)).

### Stretch goal (researched in Phase 0, shipped as soon as possible)

- **VRR.** Gamescope is ready, but the board's HDMI goes through a DP→HDMI bridge whose VRR support is unknown, and mainline `msm` DP has no Adaptive-Sync yet. A one-hour register check in Phase 0 decides whether it's possible ([PERFORMANCE.md §3](PERFORMANCE.md#vrr-stretch-goal-a-big-win-if-the-hardware-allows-it)). If the bridge can't do it, 120 Hz output with even frame caps is the fallback.

### Deferred to v2

- Installing Valve's bundles *unmodified* through a sysext device layer. This was PLAN.md's primary path; it's now an optimisation. See UPDATES.md §1 for why.
- Reliable deep sleep (v1 uses a freeze-based standby)
- HDMI-CEC
- 4K-output tuning
- Wi-Fi-only installer

### Dropped

- CPU and RAM overclocking. The limits are locked in signed Qualcomm firmware (PLAN.md §7).
- Qualcomm's proprietary Adreno driver. It needs Qualcomm's downstream KGSL kernel and can't coexist with the mainline display driver that gamescope uses (UPDATES.md §3).

## What to do first

### Step 1: Hardware (order now)

| Item | Why |
|---|---|
| Q6A **12 or 16 GB** | Frame userspace + FEX + Proton need the RAM |
| 2230 M.2 NVMe (PCIe 3.0) | Target install disk |
| Heatsink + fan | Sustained GPU clocks |
| **3.3 V USB-UART adapter** | Serial console: essential when HDMI or gamescope is black |
| USB stick / SD card | Recovery and test boots (UEFI tries USB/SD before NVMe) |
| HDMI dummy plug *or* USB HDMI capture dongle | Headless testing; the capture dongle lets CI screenshot gamescope |
| *Recommended:* a **second Q6A** + smart plug | Dedicated CI test rig (UPDATES.md §4). Without it, your own board is the test rig. |

### Step 2: Gamescope check on real hardware (about 1 week)

This decides whether the project goes ahead, so it comes before any image building. Each step builds on the previous one:

1. Flash the current Radxa SPI firmware (EDL + `edl-ng`). Install **Armbian `qcs6490` edge (mainline 7.1)** to the NVMe.
2. Confirm HDMI, Ethernet, `vulkaninfo` and `vkcube` on Turnip (Adreno 643).
3. Download and verify Valve's current Frame rootfs on the board: signed RAUC bundle, then casync chunks, then sha256 check.
4. `systemd-nspawn` into it with `/dev/dri`, input and the seat passed through. Run **Valve's own gamescope `--backend drm`** with `vkcube` on HDMI (G0).
5. Do the same with the handheld project's **MSM gamescope build** for comparison.
6. Launch the Steam client's gamepad UI inside gamescope: G1–G4 (Quick Access Menu, direct scanout, compressed buffers, hardware scaling).
7. Also check, while the board is set up:
   - **VRR/ALLM:** read the bridge's DPCD capabilities via `/dev/drm_dp_aux*` and whether a FreeSync/VRR TV's EDID range survives the bridge
   - **120 Hz:** 1080p120 mode set on a TV that supports it
   - **Fan:** what the cooling kit connects to, and whether a PWM line is reachable
   - **Audio:** headset jack and HDMI audio with the AudioReach topology
   - **Bluetooth:** pairing a controller on the AIC8800
8. Write the results to `docs/spike-results.md`. Decide: stock gamescope or patched? Is Valve's Mesa OK on the A643, or do we need our own build from day one?

**Go** if Game Mode's UI shows on the TV with either binary. **No-go** only if `drm/msm` can't drive the HDMI bridge from gamescope at all. That would be a kernel bug to fix before anything else, not a dead end.

### Step 3: Work that needs no hardware (can start immediately, in parallel)

- Repo skeleton (PLAN.md §10), `versions.env` with every upstream pin
- `fetch-valve-rootfs`: download, verify Valve's signature and chunk hash, unpack. Step 2.3 uses it.
- The **watcher workflow** (UPDATES.md §2): polls Valve, Mesa, kernel and firmware upstreams and opens version-bump PRs
- The **Mesa four-slice build** (aarch64, x86_64 and i386 FEX guests, Android) for the `mesa-stable` and `turnip-main` channels
- A spike script that automates Step 2.3–2.6 on the board, so it can be rerun on every new Valve build

### After that: milestones

| # | Milestone | Exit criterion |
|---|---|---|
| M1 | **First boot from NVMe** | Our kernel (Valve 7.2 + Armbian Q6A patches) boots Valve's rootfs to Game Mode on HDMI |
| M2 | **Game Mode complete** | G0–G10 pass; Desktop Mode round-trip; HDMI + jack + BT audio; BT controllers; network |
| M3 | **Updates end-to-end** | Watcher → build → hardware test → publish → device updates from the Steam UI → rollback proven |
| M4 | **Parity** | Lepton, Remote Play, recording, Decky; every v1 row in PLAN.md §2 checked |
| M5 | **Performance and tuning** | Driver channels with automatic fallback; GPU OC + stability test; fan curve and profiles; per-game profiles; benchmark tracking in CI; VRR if Phase 0 says the bridge allows it |
| M6 | **Public beta** | Installer, docs, release notes generated from the pipeline |

M3 deliberately comes before M4. Once updates are automated and tested, every later feature ships through the real pipeline, and Valve releases stop being something we chase by hand.
