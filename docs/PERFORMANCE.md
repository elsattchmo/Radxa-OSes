# Performance, overclocking, thermals and VRR

The Q6A's GPU has roughly a quarter to a third of the Steam Frame's throughput, so **every performance technique the stack allows is in scope for v1**. This document lists them all, what each costs, and how they're exposed: the Quick Access Menu (QAM), per-game profiles, and system-wide performance profiles.

Rule for every item below: **measure on the Q6A before making it a default.** Several techniques that help on a Deck (frame generation, heavy upscalers) can cost more than they give on a GPU this small.

## 1. Upscaling

| Technique | Level | Works with | Cost on A643 | Default |
|---|---|---|---|---|
| **SGSR 1** (Snapdragon Game Super Resolution + RCAS) | gamescope (`-F sgsr`) | Any game | Low; designed for Adreno | **Yes**, for games rendering below output resolution |
| **FSR 1** | gamescope (`-F fsr`) | Any game | Low–medium | QAM option |
| **NIS** | gamescope (`-F nis`) | Any game | Low–medium | QAM option |
| Integer / nearest | gamescope | Pixel-art, 540p→1080p | ~0 | QAM option |
| **FSR 2 / 3.x upscaling** | In-game | Games that ship it | Medium (compute) | Per game; usually beats SGSR on quality at 720p→1080p |
| XeSS (DP4a path) | In-game | Games that ship it | High on A643; test | Per game, off by default |
| **OptiScaler** (community) | Proton DLL injection | DLSS-only games → FSR 2/3 or XeSS | As above | Opt-in per game |
| DLSS / FSR 4 | — | NVIDIA / RDNA4 only | — | Not available |

Typical recipe: game at **720p** (or 540p for heavy titles) → SGSR or in-game FSR → **1080p output**.

- Steam's per-game "Game resolution" setting and gamescope's nested resolution make this a one-tap QAM choice.
- The **default output stays 1080p** even on 4K TVs ([GAMESCOPE.md §4](GAMESCOPE.md#4-performance-avoid-compositing)). Upscaling to 4K costs about 4× the composite work.

## 2. Frame generation

| Technique | Notes |
|---|---|
| **lsfg-vk** (Lossless Scaling frame generation as a Vulkan layer) | Any Vulkan or DXVK game. Requires owning Lossless Scaling on Steam. The handheld ports already ship an aarch64 lsfg-vk 2.0 build, plus a Decky plugin with its x86 helper running through Box64. |
| **FSR 3 frame generation** | In-game, where offered |

Frame generation costs GPU time and adds latency. On the A643 it's most useful for **30 → 60** in slower games (RPGs, strategy, sims), and rarely for action games. It's opt-in per game. CI publishes the base and generated fps for each smoke-test title so the trade-off is visible.

## 3. Frame pacing, refresh rate and VRR

Without VRR, smoothness comes from **frame caps that divide the refresh rate evenly**:

- **HDMI 120 Hz modes.** Many TVs accept **1080p120** over HDMI 2.0, and 1440p120 fits HDMI 2.0 bandwidth too. At 120 Hz, caps of **30 / 40 / 60 / 120** are all even. **40 fps at 120 Hz** is the sweet spot for this GPU: noticeably smoother than 30, far cheaper than 60. Gamescope gets per-display refresh lists from a Lua display profile built from the TV's EDID, so Steam shows a refresh slider for external screens too.
- **50 Hz / 48 Hz modes** for PAL-era content and 24 fps video, where the TV offers them.
- **ALLM (Auto Low Latency Mode)**, to switch the TV into game mode automatically. This depends on the HDMI bridge forwarding the HDMI Forum infoframe; test in Phase 0.

### VRR (stretch goal: a big win if the hardware allows it)

VRR needs three things, and only the last is certain today:

| Layer | Requirement | Status |
|---|---|---|
| **Board** | Q6A's HDMI is the SoC's **DisplayPort** output through an **RA620 DP→HDMI 2.0 bridge**. VRR would need the bridge to accept DP Adaptive-Sync and emit HDMI VRR or FreeSync-over-HDMI. | **Unknown**; most DP→HDMI 2.0 converters don't. This is the deciding factor. |
| **Kernel** | `drm/msm` DP needs Adaptive-Sync support: the `vrr_capable` connector property, `VRR_ENABLED` on the CRTC, variable vertical total on the DPU interface. Qualcomm's downstream kernels have "Qsync" for this hardware generation; mainline `msm` has no DP VRR yet. | Kernel work required |
| **Gamescope** | Uses the generic KMS VRR properties (`--adaptive-sync`, QAM toggle) | Ready |

There's no other display output to fall back on: the board's USB-C port is for power, and the DP lanes are wired to the bridge.

**Cheap pass/fail test (Phase 0, an hour of work):** read the bridge's DPCD capability registers through `/dev/drm_dp_aux*`:

- `MSA_TIMING_PAR_IGNORED` (DPCD 0x007, bit 6), which is required for DP Adaptive-Sync
- the downstream-port capability fields describing the HDMI side

Also check whether a FreeSync TV's EDID VRR range survives through the bridge.

- **Bridge doesn't advertise Adaptive-Sync:** VRR is impossible on this board. Record it and move on; the 120 Hz + even-cap approach above is the answer.
- **It does:** VRR becomes a v1.x milestone. Port or write `msm` DP Adaptive-Sync (upstreamable, and it would help every Snapdragon Linux device), then enable gamescope's toggle.

Ask Radxa directly for the RA620's VRR/ALLM capabilities in parallel. It's their bridge.

## 4. GPU driver techniques

- **Driver channels** `valve` / `mesa-stable` / `turnip-main` ([UPDATES.md §3](UPDATES.md#3-gpu-driver-channels)). Newer Turnip often brings real a6xx gains. Selectable per game as well as globally.
- **OpenGL path per game.** Valve only builds **zink** (GL on Vulkan). Our Mesa channels also build the native **freedreno** GL driver, which can be faster for GL games on a6xx. Per-game toggle (`MESA_LOADER_DRIVER_OVERRIDE`).
- **Turnip debug knobs per game**, e.g. `TU_DEBUG=sysmem` vs the default tiled (GMEM) rendering. Valve already sets `sysmem,preempt` for its VR compositor. Exposed as per-game presets, not raw env editing.
- **Compressed buffers (UBWC)** on by default if gamescope test G3 passes. Saves memory bandwidth, the scarcest resource on this SoC.
- **Shaders.** Steam shader pre-caching on, with the Mesa disk cache on NVMe. Big cache size, so long sessions don't recompile.
- **Variable-rate shading** (the Deck's "half-rate shading") only if Turnip exposes `VK_KHR_fragment_shading_rate` on a6xx. Verify; it may be a7xx-only.

## 5. x86 translation and Proton

- **Proton ARM64EC.** Wine runs natively on arm64 and only the game's x86 code goes through FEX in-process. This is the fastest path for Windows games and is what the Frame ships.
- **FEX per-game profiles**, as in the handheld ports:
  - `fast`: reduced-precision x87, ntsync
  - `fastest`: also turns off x86 memory-ordering emulation (TSO); can crash multithreaded games
  - `compat`: strict TSO and split-lock emulation
- **FEX thunks.** Route the game's x86 Vulkan and GL calls to the native arm64 Mesa instead of an emulated x86 Mesa. This can be a large win; check how Valve's FEX config uses them (Phase 0).
- **Box64** as an alternative translator per game. The handheld ports bundle it; some titles run better.
- **DXVK / VKD3D-Proton** tuning per game (e.g. `WINE_D3D_CONFIG=renderer=vulkan` for old D3D titles). `ntsync` is in our kernel.

## 6. CPU, memory and storage

- **Thread placement.**
  - Game process tree → the **A78 cores** (2.7 + 3×2.4 GHz) via a cpuset on the game slice.
  - Steam client, downloads, shader compilation in the background, and IRQs → the **A55 cores**.
  - `uclamp` boost for the game's main/render threads.
- **Memory.** zram swap (Valve's `holo-zram-swap`), transparent huge pages for games, and Steam downloads throttled while a game runs. RAM is shared with the GPU, so the 12/16 GB models matter.
- **Storage.** NVMe for games and shader cache. The PCIe 3.0 x2 link caps at about 2 GB/s, which is plenty.

## 7. Overclocking (v1)

| Knob | What we do | Safety |
|---|---|---|
| **GPU 840 / 900 MHz** | DT overlay enabling the upstream `TURBO` / `TURBO_L1` OPPs for the Q6A's speed bin (from the GPU speed-bin fuse). About +11% over 812 MHz. | Same voltage corners Qualcomm uses for faster bins |
| **GPU experimental (>900 MHz)** | Optional overlay adding higher steps on the top voltage corner. Only offered after the **built-in stability test** passes on *your* board. | Likely unstable on most chips, since there's no higher voltage corner. Auto-reverts on a GPU hang. |
| **Memory bandwidth floor** | Performance/OC profiles raise the GPU's DDR bandwidth votes and devfreq floor | Power/heat only |
| **CPU sustained clocks** | Performance governor, raised min-frequency floors on the A78 clusters | No clock increase is possible: the 2.7/2.4/1.96 GHz limits are locked in signed firmware |

**Stability test** (`q6a-tuned stress`): vkmark + a Vulkan compute soak + a capture-checked gamescope scene at each candidate clock, for 10–30 minutes.

- It logs GPU faults (`msm` recovery events), temperatures and throttling.
- A clock is only offered if it passes.
- If a GPU hang happens later in normal use, the next boot drops back to the last stable clock automatically.
- The boot menu always has a **"Safe (stock clocks)"** entry.

## 8. Thermal control

- **Sensors.** SoC tsens zones (per CPU cluster, GPU, modem/other) from `kodiak.dtsi`, plus the Q6A's board ADC zones (`msm-skin`, `quiet`, `ufs`, `xo`). All exported through hwmon so the QAM performance overlay (MangoHud/mangoapp, with the Qualcomm patches the handheld ports carry) shows CPU/GPU temperature, clocks and load.
- **Fan.** The mainline Q6A device tree describes **no fan**. Phase 0 must establish what Radxa's cooling kit connects to.
  - If there's a PWM-capable header or a usable GPIO/PMIC PWM pin: add a `pwm-fan` node with cooling maps, and `q6a-tuned` drives a fan curve.
  - Otherwise: an always-on 5 V fan, with a recommendation for which one.
- **Trip points.** Stock trips are conservative. Performance/OC profiles raise the *passive* (throttle) trips via DT overlay. The hardware limits-management throttling in Qualcomm's firmware stays untouched as the last line of defence.
- **Throttle visibility.** `q6a-tuned` logs when and why clocks dropped (thermal vs power vs firmware limits) so performance numbers can be trusted.

## 9. Profiles and controls

| Profile | GPU max | CPU | Fan | Trips | Use |
|---|---|---|---|---|---|
| Silent | 608 MHz | schedutil, low floors | quiet curve | stock | Streaming, video, 2D |
| Balanced (default) | 812 MHz (stock) | schedutil | default curve | stock | Most games |
| Performance | 840 MHz | A78 floors raised, game cpuset | aggressive | raised | Heavier games, needs fan |
| Overclock | 900 MHz (+ experimental if passed) | A78 at max, uclamp boost | max | raised | Heaviest games, needs fan |

- **Global** profile from a Decky plugin in the QAM. A `steamos-manager` integration is preferable if Valve's ARM build exposes a performance-profile interface (check in Phase 0).
- **Per-game profiles** keyed by Steam app ID, applied automatically on launch: performance profile, render resolution, upscaler and sharpness, frame cap/refresh rate, frame generation on/off, FEX profile, driver channel, GL driver, Turnip preset.
- **Community presets.** Profiles can be exported and imported as small files, so a known-good setting for a game can be shared.

## 10. Benchmarks and regressions

The hardware test rig ([UPDATES.md §5](UPDATES.md#5-hardware-in-the-loop-testing)) runs a fixed benchmark set on every build, per driver channel: vkmark, a few native ARM64 games, a few Proton/FEX titles, and a Lepton game, at Balanced and Overclock. Results are graphed over time.

- A **>5% regression** blocks promotion to `stable` and opens an issue naming the `versions.env` change that caused it.
- Improvements are reported in the release notes.
