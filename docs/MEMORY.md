# Running light on an 8 GB Q6A

The development board has **8 GB**, and that's the target: a system that works well with 8 GB, not one that needs 12 or 16. The Steam Frame has 16 GB, so Valve's defaults may assume more headroom than we have.

On this SoC, RAM is also the GPU's memory. Everything the OS keeps resident is taken away from the game's textures and buffers.

## 1. Budget

| Consumer | Budget (8 GB board) | Notes |
|---|---|---|
| Firmware and co-processor reservations | **~0.45 GB** on current firmware | The latest `wp` firmware's memory map reserves ~464 MiB, against ~142 MiB on the older Linux-only firmware. Most of it is sized for a modem and Wi-Fi co-processor the Q6A doesn't have ([FIRMWARE.md §2](FIRMWARE.md#2-the-memory-cost-of-the-wp-firmware)). We're asking Radxa for a trimmed map. Confirm with `MemTotal` in Phase 0. |
| **OS + Game Mode idle** | **≤ 1.3 GB used** (stretch: ≤ 1.0 GB) | Steam client + web helper, gamescope + 2 Xwayland servers, PipeWire, NetworkManager, BlueZ, InputPlumber, systemd/journald. Excludes reclaimable page cache. |
| **Game + its GPU allocations** | **≥ 6 GB** | What the user actually bought the board for |
| Desktop Mode, Lepton (Android), browsers | 0 while a game runs | Separate session or started on demand; never resident during a game by default |

These numbers are targets until the Phase 0 measurement. The first job is to **measure** Valve's Frame image in Game Mode on the Q6A, using `ps_mem` (which is in Valve's image), `smem` and `systemd-cgtop`, then cut.

## 2. Remove what the Frame runs and we don't need

Masking these is already required for correctness. On 8 GB it's also the biggest saving:

- **SteamVR:** compositor, server, monitor and the VR session units. The single largest item.
- Tracking/camera and FPGA/display services, ADB and USB gadget, the Frame power monitor, `deckard-fan-control`
- Profiling daemons that may be on by default: Perfetto `traced`, GPU tracing. The debug tools in the image (bpftrace, lldb-server, openocd…) are only installed, not running, so they cost disk, not RAM.
- The VR-nested Plasma session (`steamvr-plasma`)
- Anything else Phase 0 finds running in Game Mode that a TV box doesn't need. Each mask is recorded with its measured saving.

## 3. Keep the essentials small

- **Steam client.** The gamepad UI runs on Steam's embedded Chromium web helper, the largest resident userspace item after SteamVR. We'll measure Steam's own options, such as GPU-accelerated web views, and how much memory store and library pages keep once closed. We adopt whatever lowers memory without breaking the UI. No promises until measured.
- **Gamescope.** Keep `--xwayland-count 2` (Steam and the game need separate X servers). `mangoapp` only matters when the performance overlay is on.
- **Shader pre-caching** (`fossilize_replay`) is memory- and CPU-hungry. Limit it to 1–2 threads on the A55 cores and pause it while a game runs.
- **Downloads and updates while gaming** are allowed but throttled. Valve OS updates install in the background into the inactive slot, at low I/O and CPU priority.
- **Lepton (Android)** brings a whole Android userspace. It starts only when an Android app launches and stops when the last one exits. It never runs beside a Steam game unless the user starts both.
- **Desktop Mode** is a separate session, so Game Mode never pays for it. Trimmed defaults: no Baloo file indexing, no KDE Connect, no background Discover/Flatpak update checks.

## 4. Memory pressure: degrade gracefully, never crash the session

- **zram** (Valve's `holo-zram-swap`): zstd, sized to about half of RAM. Steam's web helper and other idle anonymous memory compresses well, which effectively adds gigabytes for cold pages.
- **Small NVMe swapfile** (2–4 GB, lower priority than zram) as a backstop, so a spike doesn't kill anything
- **Kernel tuning:** MGLRU on; swappiness tuned for zram; `min_free_kbytes` sized so GPU allocations don't stall
- **OOM order** (systemd-oomd / `OOMScoreAdjust`). The user's game and the session must be the last things to die:
  1. first to go: shader pre-compilation, Lepton, Desktop/Flatpak apps
  2. then the game, only if it alone exceeds memory
  3. protected: gamescope, Steam client, PipeWire, InputPlumber, NetworkManager
- **Pressure feedback:** `q6a-tuned` watches PSI (pressure stall information). Under sustained pressure it can stop background work automatically: shader compile, downloads, Lepton.

## 5. GPU memory (unified)

Turnip reports a GPU memory heap based on system RAM. Many PC games pick texture quality from reported VRAM, so they over-allocate on an 8 GB machine and push the system into swap.

- **Report less VRAM.** Valve already builds the `vram-report-limit` Vulkan layer into the Frame's Mesa (`-D vulkan-layers=vram-report-limit`). We enable it with a limit scaled to RAM, e.g. about 2.5–3 GB on 8 GB boards (to be tuned in Phase 0), so games choose sensible texture settings.
- Per-game overrides through the DXVK/VKD3D settings (`dxgi.maxDeviceMemory` and similar) in the per-game profiles ([PERFORMANCE.md §9](PERFORMANCE.md#9-profiles-and-controls))
- Compressed GPU buffers (UBWC) where gamescope test G3 passes. They save bandwidth rather than capacity, but reduce memory pressure on the shared bus.

## 6. Kernel and firmware

- **Reclaim unused reservations** with a DT overlay. These are only safe to free if we don't use them:

  | Region | Size | Used for |
  |---|---|---|
  | `cdsp_mem` | 30 MiB | the CDSP/NPU (AI accelerator), not needed for gaming |
  | `cdsp_secure_heap_mem` | 30 MiB | CDSP secure memory |
  | `camera_mem` | 5 MiB | camera |
  | `cvp_mem` | 5 MiB | computer-vision block |

  That's about 70 MiB in total. Re-enabling them for AI users is a profile toggle. Never touch the TrustZone/hypervisor regions (`qtee`, `trusted_apps`, `tz_stat`, `tags`, `hyp`), since firmware writes to them.
- **Small CMA.** The GPU and display both sit behind the IOMMU, so a small CMA area (about 32 MiB) is enough. Verify that video decode (Iris) doesn't need more.
- **Production kernel config.** Use Valve's non-`hwdebug` config as the base. No kmemleak or other debug allocators; keep only the `tracefs` that mangoapp and steamos-manager need.

## 7. CPU "lightness" too

A light system also keeps the CPU idle when it should be, which means less heat, more GPU headroom and higher sustained clocks:

- Game Mode idle target: **< 3% total CPU**, with **no periodic wakeups** above a few per second from our services. `q6a-tuned` polls with backoff and is event-driven where possible.
- Background work (Steam client housekeeping, journald, NetworkManager) is pinned to the A55 cores; the A78 cores are kept for the game ([PERFORMANCE.md §6](PERFORMANCE.md#6-cpu-memory-and-storage)).

## 8. Disk

Disk matters less than RAM, but for completeness:

- Each rootfs slot is about 10 GB (Valve's image size), and there are two.
- Because v1 builds our own bundles ([UPDATES.md §1](UPDATES.md#1-key-decision-we-ship-one-tested-bundle-per-combination)), we *could* strip packages the Q6A never loads: SteamVR-only components, Android developer tools, hardware debug tools. That saves disk, not RAM, and makes diffing against Valve harder, so only clear dead weight gets removed.
- A 128 GB NVMe is the practical minimum once games are installed.

## 9. Keeping it light over time: CI gate

The hardware test rig ([UPDATES.md §5](UPDATES.md#5-hardware-in-the-loop-testing)) records a **memory report** for every build. It boots to Game Mode, waits for idle, and logs per-service memory use (PSS), zram ratio and CPU idle load.

- **If idle "used" exceeds the budget by more than 5%**, promotion is blocked. The report names the new or grown process, e.g. a service Valve added in a new Frame build that we need to mask.
- The memory report and its trend go into the release notes.
- The game smoke tests also record peak memory and swap activity, so a Mesa/Turnip channel that leaks or over-allocates is caught before it ships.
