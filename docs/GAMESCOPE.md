# Gamescope on the Q6A

Gamescope is the compositor behind Game Mode. It owns the display and hosts Steam's gamepad UI and the Quick Access Menu. Frame limiting, upscaling, the performance overlay, screenshots and recording all run through it. If gamescope is wrong, the OS feels wrong, so it's the critical path of this port.

## 1. The core problem: the Frame doesn't use gamescope the way we need

On the Steam Frame, gamescope **never drives a display**. Valve's session script (`/usr/lib/steamos/gamescope-session`, from the `deckard-steamvr-session` package) runs:

```
gamescope --backend openvr --vr-session-manager \
          --nested-width 1280 --nested-height 720 \
          --output-width 1920 --output-height 1080 \
          --vr-overlay-key valve.steam.gamepadui.fallback ... --steam --mangoapp
```

- Games and the Steam UI are rendered into **SteamVR overlays** at a virtual 1920×1080. SteamVR's compositor then puts them on the headset panels.
- `gamescope-session.service` is `PartOf=steamvr.service`, so gamescope exits if SteamVR does.
- **Desktop Mode** is KDE Plasma nested inside a second gamescope, also shown as a VR overlay (`plasma-session.target`, `steamvr-plasma.service`).

On the Q6A, gamescope has to run with **`--backend drm`**: the Steam Deck path, driving HDMI through KMS, with direct scanout and hardware planes. That backend is the same code Valve ships to every Deck, but **Valve has never run it on Qualcomm's display driver** (`drm/msm`, DPU). Turning the headset session into a TV session is mostly gamescope work, which is why it gets its own document.

## 1a. Prior art: who has gamescope on Qualcomm displays already

| Project | Base | Gamescope status | Useful to us |
|---|---|---|---|
| **hashtagbasit/SteamOS-ARM-Handhelds** (includes MaSi's SM8550 work) | Valve's Frame image + ROCKNIX-based kernels, SM8250–SM8750 | **Working.** Runs `--backend drm` on `drm/msm` with an "MSM port" of gamescope 3.16.30. An external monitor on USB-C/HDMI takes over Game Mode with HDMI/DP audio, as on a Deck. | **Yes, our starting point.** Session script, SteamVR decoupling drop-ins, the env handoff to `steam.service`, the build-inside-the-Frame-rootfs script, and patches for MSM quirks: a linear-only switch for compressed buffers, a forced composite for scaled layers, compositor rotation, EDID-less refresh tables. GPL-2.0. |
| **Armada → Nebel** (Ga1dz1) | Fedora bootc, *not* Valve's image; SM4450–SM8750 | External monitors in Game Mode since the 2026-09-07 beta | Confirms the approach works, but most code is now in private repositories |
| **DroidDeck** | Runs inside Android (PRoot) | Not a KMS compositor setup | No |

**Nobody has done this on the QCS6490 or on any SBC yet.** Every existing port targets a handheld's built-in DSI panel first, with HDMI/DP as a secondary output, and runs on bigger display engines than the SC7280's. What's still ours to solve:

- the RA620 DP→HDMI bridge
- the one-scaler, 2400 px-per-pipe plane limits, which affect 4K (section 3)
- whether compressed (UBWC) scanout works on this exact GPU and display pairing
- tuning the defaults for a TV rather than a panel. Their `--force-composition`, `--generate-drm-mode fixed` and `--adaptive-sync` are panel choices we don't want (section 4).

Phase 0 therefore tests **both** Valve's stock binary and their MSM build on the Q6A. We take whichever passes G0–G4 with fewer patches, and upstream what we can.

## 2. What we get for free

- **The binary.** Valve's `gamescope` package is upstream `ValveSoftware/gamescope` built with default meson options, so the DRM backend (wlroots + libliftoff + libdisplay-info) is compiled into the Frame image. The Frame-era version also brings:
  - the stand-in connector for headless sessions (`3.16.30`)
  - the **SGSR** upscaler (`-F sgsr`, Snapdragon Game Super Resolution). It was designed for Adreno and is a good default filter on this GPU.
- **Steam integration.** The `--steam` mode atoms give us the Quick Access Menu's frame limiter, scaling filter (FSR/NIS/SGSR/integer), the perf overlay via `mangoapp`, screenshots, and the PipeWire stream used by game recording and by Remote Play when the Q6A is the host.
- **The x86 WSI layer.** `deckard-gamescope-layer-x86_64` installs gamescope's Vulkan WSI layer into the FEX rootfs, so x86 games running under FEX/Proton present through gamescope properly.
- **Turnip features gamescope needs**, all present: DRM format modifiers, `VK_EXT_physical_device_drm`, dma-buf import/export, sync-file/timeline semaphores.

## 3. What the Q6A's display hardware offers gamescope

From the SC7280 DPU catalogue (`drivers/gpu/drm/msm/disp/dpu1/catalog/dpu_7_2_sc7280.h`) and the board's HDMI path (DP → RA620 bridge → HDMI 2.0):

| Capability | Q6A (SC7280 DPU) | What it means for gamescope |
|---|---|---|
| Hardware planes | 1× VIG (scaler + inline rotation), 3× DMA (no scaling; 2 cursor-capable) | Direct scanout works, but **only one layer can be scaled in hardware**. The cursor gets a real plane. |
| Plane width | 2400 px per pipe, 2560 px per mixer | 1080p/1440p: one pipe per plane. **4K needs two pipes per plane** ("virtual planes", now on by default in `drm/msm`) plus 3D merge, which halves the plane budget. |
| Colour pipeline | DSPP with a 3×3 colour matrix (PCC); no per-plane degamma/shaper/3D LUT | AMD-only colour properties don't apply. Gamescope does colour work (night mode, colour sliders) in its Vulkan composite path, as it does on Intel. |
| HDR | No HDR metadata path in mainline `msm` DP; RA620 unknown | **No HDR.** The Frame's flat mode has no HDR either, so this isn't a parity loss. |
| VRR | No adaptive-sync in mainline `msm` DP; bridge support unknown | Gamescope's VRR support is ready, but VRR needs bridge support plus kernel work. It's a **stretch goal** with a Phase 0 pass/fail check ([PERFORMANCE.md §3](PERFORMANCE.md#vrr-stretch-goal-a-big-win-if-the-hardware-allows-it)). Fallback: 120 Hz HDMI modes with even frame caps. |
| Tearing/async flips | `DRM_CAP_ATOMIC_ASYNC_PAGE_FLIP` probably not exposed (verify) | The QAM "allow tearing" toggle will likely be greyed out. |
| Compressed scanout (UBWC) | DPU can scan out UBWC buffers that Turnip produces | Saves a lot of memory bandwidth on a bandwidth-starved SoC. The handheld ports saw corruption and added a "linear only" switch; **must be tested** here (see G3). |
| EDID / orientation | Real EDID over HDMI, landscape | Most of the handheld ports' gamescope patches (EDID-less DSI panels, rotation, dual screens) **aren't needed**. |

## 4. Performance: avoid compositing

Gamescope has two paths per frame:

1. **Direct scanout.** The game's buffer goes straight to a hardware plane. It costs almost no GPU time.
2. **Vulkan composite.** Gamescope runs a compute pass to blend layers, scale, apply colour or upscale. It costs GPU time every frame.

On the Frame's Adreno 750 the composite cost doesn't matter. On the Adreno 643, which has about a quarter of the throughput and shares one memory bus with the CPU, it competes directly with the game. The handheld ports run with `--force-composition` (always composite), mostly because their panels are rotated. **We shouldn't copy that.**

Our defaults:

- **Output 1080p60 by default, even on a 4K TV**, and let the TV scale. The A643 can't render most games at 4K. A 4K composite touches 4× the pixels, and 4K needs the double-pipe plane setup. Qualcomm rates the QCS6490's DisplayPort output, which feeds the Q6A's HDMI bridge, at **4K 30 fps** (two lanes at HBR3). So 4K output is a 30 Hz desktop/video mode, not a gaming mode. **1080p120** fits the link; 1440p120 doesn't.
- **Render games at 720p–1080p.** At 1080p output a 1080p game scans out directly. Lower resolutions use gamescope's upscaler; SGSR is the default and FSR/NIS/integer are selectable in the QAM. Upscaling always composites, but then it's buying something.
- **Composite only when needed:** upscaling, Steam overlay or notifications visible, colour sliders or night mode active, or a hardware-scaling glitch (see G4).
- **Measure, don't guess.** Valve's Mesa is built with Perfetto support, so gamescope's composite cost on Turnip can be measured per frame. Every default above is validated with numbers in the acceptance tests below.

## 5. Session changes

All of these ship in our device layer. No rootfs files are edited.

1. **Decouple from SteamVR**, using a drop-in like the handheld ports do (`gamescope-session.service.d/50-q6a.conf`):
   ```ini
   [Unit]
   PartOf=
   PartOf=graphical-session.target
   [Service]
   ExecStart=
   ExecStart=/usr/lib/q6a/gamescope-session
   ```
2. **Our session script** (`/usr/lib/q6a/gamescope-session`). It keeps Valve's setup (stats pipe, ready-notify, low-disk cleanup, IM/Qt env, holo cursor) and swaps the VR arguments for DRM ones:
   ```
   --backend drm --prefer-output <HDMI connector>
   -W <out_w> -H <out_h> --nested-width <out_w> --nested-height <out_h> --nested-refresh <hz>
   -F sgsr --steam --mangoapp --xwayland-count 2 --max-scale 2 -T "$stats"
   --cursor /usr/share/holo/holo-cursor.png --cursor-scale-height 720
   --hide-cursor-delay 3000 --fade-out-duration 200 --framerate-limit 0
   ```
   - Output resolution and refresh rate come from a user setting (default 1920×1080 at the EDID's preferred refresh rate).
   - No `--force-composition`.
   - The `--vr-*` arguments and `--virtual-connector-strategy` are dropped.
3. **Hand the environment to Steam.** `steam.service` doesn't inherit gamescope's environment, which costs the refresh-rate/frame-limit UI and mangoapp. We write `STEAM_DISPLAY_REFRESH_LIMITS`, `STEAM_USE_MANGOAPP` and similar to a file that `steam.service` reads, as the handheld ports do.
4. **Desktop Mode.** Run Plasma on **native KWin Wayland on KMS**, the way the Steam Deck does. "Switch to Desktop" goes through `steamos-session-select` and SDDM autologin. The fallback is Plasma nested in gamescope-drm, which is closer to the Frame and needs no KWin bring-up, but is slower and has worse input handling.
5. **TV behaviour.**
   - Hotplug: TV off/on, input switching, a different TV.
   - Booting with the TV off: gamescope's stand-in connector keeps the session alive so Remote Play hosting still works.
   - HDMI audio follows the active connector.
   - HDMI-CEC (TV remote → Steam input, standby) is a stretch goal and depends on the DP→HDMI bridge exposing CEC.

## 6. Which gamescope binary we ship

**Preferred: Valve's own, unmodified.** It updates with every Valve release and always matches the Steam client's gamescope protocol version. Everything in section 5 is configuration only.

**If Q6A bugs need code fixes** (likely candidates: UBWC scanout, VIG scaling flicker, DP/bridge mode quirks):

- Keep a **small patch queue** in `gamescope/patches/` and send every patch upstream to `ValveSoftware/gamescope`. Fixes for `msm` help the Frame too, once anyone drives a real display from it.
- CI rebuilds our gamescope for **every Valve release**, from the exact commit Valve used (the `_commit` in Valve's source tarball for that build), plus our patches. The build runs inside that release's rootfs, so it links against the same glibc, wlroots and libdrm.
- The build ships in the sysext. A CI gate refuses to ship if our patches don't apply to Valve's new commit; that release then falls back to Valve's binary plus config workarounds.
- **Never ship a gamescope older than Valve's.** Steam's UI expects features from the version Valve paired it with.

## 7. Acceptance tests

These run in Phase 0 against the Frame rootfs (inside `systemd-nspawn` with `/dev/dri`) on the Armbian edge kernel (mainline 7.2), and again on every release.

| ID | Test | Pass |
|---|---|---|
| G0 | Valve's gamescope, `--backend drm`, `vkcube` on HDMI | Correct mode from EDID; log shows connector, modifiers and libliftoff plane assignment |
| G1 | Full Game Mode: Steam gamepad UI at 1080p60 | UI renders, QAM opens; frame limiter, upscaler choice and perf overlay work |
| G2 | Direct scanout | A fullscreen 1080p game at 1080p output with the overlay hidden: zero composites per frame (gamescope stats/debug HUD) |
| G3 | UBWC vs linear | No corruption with modifiers on; if it's clean, measure the bandwidth/FPS gain. Otherwise, linear only with a bug filed upstream |
| G4 | VIG hardware scaling (720p → 1080p) | No flicker; otherwise force a composite when scaling, as the ports' patch does |
| G5 | 4K output (expected max 4K30, per Qualcomm's DP spec) and 1080p120 | Modes set; confirm whether the RA620 bridge allows anything beyond 4K30; composite cost measured |
| G6 | Hotplug and TV power cycle; boot with TV off | Session survives and recovers the picture; Remote Play host still reachable |
| G7 | Screenshots, game recording, Remote Play host | Files and stream produced. Encoding uses the Iris hardware encoder (V4L2 → VA-API shim) where possible |
| G8 | Frame pacing | 60/40/30 fps caps on 60 Hz are even (frametime plot); GPU composite cost recorded with Perfetto |
| G9 | x86 game via FEX + Proton | Presents through the gamescope WSI layer; QAM controls apply |
| G10 | Game Mode ↔ Desktop Mode | Round-trip ×10 with no stuck black screen |

## 8. Risks specific to gamescope

| Risk | Mitigation |
|---|---|
| `msm` atomic commits rejected for layouts gamescope tries (EINVAL → black screen) | libliftoff falls back to composition automatically. Capture failing commits with `drm.debug` and fix in the kernel or the patch queue |
| UBWC corruption | Linear-only switch (the handheld ports' `GAMESCOPE_DISABLE_MODIFIERS`), at a bandwidth cost |
| Composite too expensive on A643 | 1080p default output, direct-scanout-friendly defaults, SGSR over FSR |
| Valve changes the session or gamescope behaviour in an update | CI watcher diffs `deckard-steamvr-session` and the gamescope commit per Valve build; our config is checked against it in the QEMU smoke test, and fully on hardware |
| Steam client shows Frame-only UI (VR settings, headset prompts) | Hide via Steam launch arguments and env as the handheld ports do; report anything left |
| `mangoapp` (OpenGL via zink) misbehaves | Already seen on the Odin 3. Fall back to Vulkan MangoHud in-game |

## Sources

- Valve's Frame session and gamescope packaging: `deckard-steamvr-session` (`gamescope-session`, `gamescope-session.service`, `mesavars.sh`) and `gamescope` PKGBUILD in https://github.com/evlaV/deckard
- Handheld ports' MSM gamescope fork, DRM-backend session script, drop-ins: https://github.com/hashtagbasit/SteamOS-ARM-Handhelds (`external-and-mods/gamescope`, `steamos-overlay/usr/lib/steamos/gamescope-session`, `scripts/build-gamescope-in-rootfs.sh`)
- Upstream gamescope (DRM backend, SGSR, stand-in connector): https://github.com/ValveSoftware/gamescope
- SC7280 DPU capabilities: `drivers/gpu/drm/msm/disp/dpu1/catalog/dpu_7_2_sc7280.h`; virtual planes: `dpu_kms.c` (`dpu_use_virtual_planes`), mainline Linux
- Q6A HDMI path (RA620 DP→HDMI bridge): https://github.com/armbian/build/pull/10162, https://github.com/qualcomm-linux/meta-qcom-3rdparty/pull/50
