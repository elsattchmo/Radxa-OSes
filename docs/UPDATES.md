# Update automation: Valve, drivers, kernel, firmware

Goal: whenever an upstream changes, build a new system image automatically, test it on a real Q6A, and offer it to devices through Steam's normal "Check for updates" with A/B rollback. Upstreams are Valve's SteamOS, Valve's Mesa and gamescope, upstream Mesa/Turnip, the kernel (Armbian/Radxa/Valve) and firmware.

## 1. Key decision: we ship one tested bundle per combination

PLAN.md §6.1 proposed letting devices install Valve's bundle directly and putting our parts alongside it. Now that GPU drivers and gamescope are also on our update list, that has a flaw. The device would combine Valve build N with our layer, our Mesa and maybe our gamescope, and **that exact combination was never tested** before it ran.

So v1 uses what was the fallback path:

- CI takes Valve build N and adds our kernel, device layer, chosen Mesa build and gamescope (stock or patched). It produces one **signed RAUC bundle** that is a complete A/B rootfs image.
- That exact bundle is what the hardware test runs. Users get byte-for-byte what was tested.
- Devices point `atomupd` at our manifest (same JSON format as Valve's) and trust our signing CA. Steam's "Check for updates" UI, delta downloads (casync chunk store) and A/B rollback work unchanged.
- Valve's image is still never redistributed as a download from us: see §6.

Direct installs of Valve's bundles (sysext route) remain a v2 option for an "untested, same-day" channel.

## 2. What we watch

A scheduled GitHub Actions workflow (`watch.yml`, hourly) polls each source. When one changes, it **opens a PR bumping `versions.env`**, the same way Renovate or Dependabot would. Merging the PR, automatically or by hand per source, triggers the build.

| Source | Endpoint | Pin in `versions.env` | Auto-merge? |
|---|---|---|---|
| **Valve SteamOS (Frame) stable** | `https://steamdeck-atomupd.steamos.cloud/meta/holo/steamos/aarch64/vr/stable.json` (`buildid`, `version`, `update_path`) | `VALVE_BUILD`, `VALVE_VERSION`, `VALVE_BUNDLE` | Yes → `rc`, then promoted |
| **Valve SteamOS rc** | `…/aarch64/vr/rc.json` | `VALVE_RC_BUILD` | Yes → `beta` |
| **Valve's Mesa and gamescope** | Source index `https://holo-packages.steamos.cloud/archlinux-deckard-hotfixes/source/` (`deckard-mesa-*-<ver>+git<sha>`, `gamescope-<ver>`, `deckard-steamvr-session-*`) | `VALVE_MESA_SHA`, `VALVE_GAMESCOPE_VER` (informational; they arrive inside Valve's rootfs) | n/a. A change triggers re-running gamescope tests and rebasing our patches |
| **Mesa stable (Turnip)** | `https://gitlab.freedesktop.org/api/v4/projects/mesa%2Fmesa/repository/tags` (`mesa-X.Y.Z`) | `MESA_STABLE_TAG` | Yes → `mesa-stable` driver channel |
| **Mesa main (Turnip)** | Mesa `main` HEAD, daily | `MESA_MAIN_SHA` | Yes → `turnip-main` driver channel (nightly) |
| **Kernel** | Valve `linux-72-deckard-*` in the source index; Armbian `patch/kernel/archive/qcs6490-7.2` and `config/sources/families/qcs6490.conf` (edge tag, currently `v7.2.3`); Radxa `radxa/kernel` `linux-6.18.2`; kernel.org stable for the base | `KERNEL_BASE`, `ARMBIAN_REF` | No. Opens a PR; humans review patch rebases |
| **Firmware** | `linux-firmware` tags; Radxa/meta-qcom Q6A firmware; AIC8800 driver | `LINUX_FIRMWARE_TAG`, `RADXA_FW_REF`, `AIC8800_REF` | Yes |
| **Q6A SPI boot firmware** | Radxa's `edk2-qualcomm` package (`edk2-qcs6490` version in Armbian's apt `trixie-utils`); the forum thread JSON; Radxa's download page | `SPI_FW_MIN` | **Never auto-flashed.** Opens an issue; the OS shows a notice if the board's firmware is older than `SPI_FW_MIN` |
| **Handheld project gamescope patches** | `hashtagbasit/SteamOS-ARM-Handhelds` `external-and-mods/gamescope` | `GS_MSM_REF` | No. Patches are reviewed before adoption |

These endpoints were all reachable at the time of writing. The Valve stable manifest showed build `20261022.6150929`; Valve's source index showed `deckard-mesa-*-26.3.0_devel+gite07916b4`, `gamescope-3.16.30-4` and `linux-72-deckard-7.2.0+g152ecbcff010`.

## 3. GPU driver channels

The driver is selectable **on the device**, separately from the OS channel:

| Channel | Contents | Who it's for |
|---|---|---|
| `valve` (default) | Valve's Mesa as shipped in that Frame build, unchanged | Everyone. Closest to Frame behaviour, and Valve tests it with Proton/FEX/Lepton |
| `mesa-stable` | Latest upstream Mesa stable tag | People who want upstream fixes sooner |
| `turnip-main` | Nightly from Mesa `main` | Testers. Newest Turnip fixes and performance |

How it works:

- Each non-Valve channel is built as the **four slices from one commit**: aarch64 (native), x86_64 and i386 (FEX guest libraries), and Android (Lepton). The handheld project's `build-mesa.sh` shows how. Mixing slices from different commits breaks FEX or Lepton games, so they always ship together.
- A channel is packaged as a **driver sysext** (`mesa-<channel>.raw`) that overlays Valve's Mesa files. Switching channel in settings (a Decky plugin and a `q6a-driver` CLI) swaps the sysext and restarts the session. No reflash, and the base image stays the tested one.
- **Automatic fallback.** After a switch, if gamescope doesn't reach "ready" or the GPU hangs within the first few minutes, the device drops back to `valve` and records why.
- Each CI build of the OS also runs the hardware tests against `mesa-stable`, and `turnip-main` nightly, so a broken driver never reaches the default channel.
- **OEM drivers.** Qualcomm's proprietary Adreno driver for QCS6490 (Qualcomm Linux) uses the **KGSL** kernel module. KGSL is now an out-of-tree module that works with the upstream device tree, so the kernel side could be made to fit. But Qualcomm's own docs list the userspace as **Vulkan 1.1 + OpenGL ES only**. Proton's DXVK/VKD3D need Vulkan 1.3, desktop OpenGL games need desktop GL, and FEX needs x86 driver builds. So it's out of scope. Turnip is the only driver that fits. Radxa's OEM contributions (kernel patches, DT, firmware) flow in through the kernel and firmware rows above.

## 4. Pipeline

```
watch.yml (hourly) ──► PR: bump versions.env ──► merge (auto for most rows)
                                                   │
             ┌─────────────────────────────────────┴───────────────────────────────┐
             ▼ slow tier (only if its pin changed, cached otherwise)                ▼ fast tier (every merge)
  kernel.yml   Valve 7.2 + Armbian qcs6490 + q6a.config  (~15 min, arm64 runner)    image.yml
  mesa.yml     4 slices × {stable, main}                  (~60–90 min)               fetch+verify Valve build
  gamescope.yml rebuild ONLY if we carry patches, from Valve's exact commit          + kernel + device layer
                                                                                     + gamescope (stock|patched)
                                                                                     → rootfs.img → casync
                                                                                     → signed .raucb
                                                                                          │
                                                                                          ▼
                                                 qemu-smoke: boots to graphical.target, unit diff vs last build
                                                                                          │
                                                                                          ▼
                                       HIL test on a real Q6A (self-hosted runner, §5) ──── fail → issue + stop
                                                                                          │ pass
                                                                                          ▼
                                       publish to channel manifest: rc → (N days or manual) → stable
                                                                                          │
                                                                                          ▼
                                       devices: Steam "Check for updates" → atomupd → RAUC → A/B + rollback
```

- Builds run on GitHub's `ubuntu-24.04-arm` runners, which are free for public repos.
- Userspace builds (gamescope, Mesa aarch64 slice) run **inside the target Valve rootfs** with bubblewrap, so they link against the same glibc and libraries. This is the handheld project's technique.
- **OS channels:**
  - `stable` = Valve stable + driver `valve`
  - `beta` = Valve rc
  - `rc` = candidate builds before promotion

  Driver channels are orthogonal (§3).
- Every published build has generated **release notes**: Valve build ID and version, kernel, Mesa SHAs per channel, gamescope version and patch list, test summary with HDMI screenshots.

## 5. Hardware-in-the-loop testing

A dedicated Q6A (ideally a second board) hooked to a small always-on host running a self-hosted GitHub Actions runner:

- **UART** console logged for every run
- a **USB HDMI capture dongle**, so tests grab real frames from gamescope's output (black-screen detection, UI screenshots in release notes)
- a **smart plug** (or USB-PD relay) for hard power-cycles
- a **USB recovery stick** left plugged in. UEFI boots USB before NVMe, so the host can force recovery by toggling a "boot recovery" flag.

The test rig installs candidates **through the real update path** (atomupd → RAUC → A/B), so every run also tests the updater. Then it runs:

1. Gamescope G0–G10 ([GAMESCOPE.md §7](GAMESCOPE.md#7-acceptance-tests)) where they can be automated, with frame captures from the HDMI dongle
2. Native ARM64, Proton/FEX and Lepton smoke titles (free games or test apps), each run for N minutes with frame-time logs
3. A reboot and a forced bad-slot test for rollback
4. A driver-channel matrix: `valve` always; `mesa-stable` per build; `turnip-main` nightly

A failure opens an issue with the logs, captures and the exact `versions.env` diff, and blocks promotion.

## 6. Legal and distribution notes

- The **installer** still downloads Valve's image from Valve and verifies Valve's signature on the user's machine.
- Our **update bundles** contain Valve's rootfs plus our changes. To avoid hosting Valve's image ourselves:
  - our casync index points at **Valve's own chunk store first** (`https://steamdeck-images.steamos.cloud/vr/chunks.castr`)
  - only chunks that our changes created come from our store

  Devices then download Valve's content from Valve and only our delta from us. (RAUC/desync support multiple chunk stores; verify Valve's store allows this access pattern before relying on it.)
- This is unofficial, unaffiliated with Valve or Radxa, and for personal use.

## 7. Implementation order

1. `versions.env` + `watch.yml` (Valve, Mesa and firmware sources first). This is useful immediately: it notifies on every Valve build even before images exist.
2. `fetch-valve-rootfs` + `image.yml` producing a raw image (M1)
3. RAUC signing, our manifest, atomupd redirection, rollback (M3)
4. HIL runner (M3)
5. `mesa.yml` + driver sysexts + switcher (M5)
6. `gamescope.yml`, only if the Step 2 check shows we need patches
