# What's inside Valve's Steam Frame image (verified)

Downloaded and inspected on 2026-10-29 with `tools/fetch-valve-rootfs.py`: stable channel, build **20261022.6150929**, version **0.4.5**. Facts here override assumptions elsewhere in the docs.

## Download and signature

- Manifest: `https://steamdeck-atomupd.steamos.cloud/meta/holo/steamos/aarch64/vr/stable.json`. The `rc` channel currently points at the same build.
- Bundle: `vr/<build>/deckard-stable-<build>-<version>.raucb` (2.2 MB). It's a RAUC "plain" bundle: squashfs, then a CMS signature, then an 8-byte size.
- **Signer:** `CN=frame-images`, issued by `CN=steamdeck-images` (Valve Corp), valid 2026-02-05 to 2126-01-12. The CA certificate isn't in the bundle, so our tool checks the signature against the content and **pins the signer's public key** (sha256 `0d277be5…632096`).
- `manifest.raucm`: `compatible=steamos-aarch64`; the rootfs is 10 GiB, with its sha256 in the signed manifest.
- **casync index:** 88,467 chunks (63,023 unique), **SHA-512/256** chunk IDs, zstd-compressed chunks. The store is `vr/<build>/deckard-…castr`, with `vr/chunks.castr` as fallback.
- **Download size: 3.97 GB.** The image is **btrfs**, 10 GiB apparent and **4.2 GB on disk** (sparse). It took about 14 minutes at about 4.8 MB/s.

## Software versions in this build

| Component | Version | Note |
|---|---|---|
| Kernel | `linux-618-deckard` 6.18.0+ge66bc2ca6f8c | **6.18, not 7.2**: the 7.2 packages in Valve's source index haven't reached stable yet |
| Mesa (Turnip + zink) | `deckard-mesa-linux-aarch64` 26.3.0_devel+gitabc426bb | Plus x86_64 and Android slices; ICD manifest at `/usr/share/vulkan/icd.d/freedreno_icd.aarch64.json`, **Vulkan 1.4.362** |
| gamescope | **3.16.28** | **No SGSR upscaler**: that arrived upstream in 3.16.30 |
| RAUC / atomupd | rauc 1.14, steamos-atomupd-client 0.20260331.1 | |
| Steam | `steam` 1.0.0.85 bootstrap | The client itself downloads at first login |
| Test tools present | `vulkan-tools` (vkcube, vulkaninfo), `mesa-utils` (glxgears), `modetest`, `xterm` | Useful for Stage 2 |

## FEX and Android

- **FEX isn't part of the OS.** `/usr/bin/FEXBash` expects FEX in `~/.steam/steam/steamapps/common/FEX-Emu`, with `SteamLinuxRuntime_4` alongside it. Steam downloads and updates both, like Proton. So we don't build or update FEX, and it can only be tested once Steam is running (Stage 3).
- The OS does ship the **x86 Mesa for FEX guests** (`/usr/share/guestos/fex-mesa`) and Android guest files for Lepton (`/usr/share/guestos/android`).
- The default user's home is `/home/steamos`.

## Boot and updates

- `/etc/rauc/system.conf`:
  - `compatible=steamos-aarch64`, `bootloader=custom`, backend `/usr/lib/rauc/bootloader-custom-backend.sh`
  - pre/post-install hooks in `/usr/lib/rauc/`
  - slots at `/dev/disk/by-partsets/{A,B}/rootfs`
  - installs with desync, seeded from `/var/lib/steamos-atomupd/rootfs.caibx`
- The custom backend just drives **`steamos-bootconf`**, Valve's A/B config format kept in the EFI partitions under `SteamOS/conf`, the same as the Steam Deck.
  - **For us:** our boot path (systemd-boot or a small loader) only has to read those bootconf files to choose slot A or B and honour boot attempts. Valve's updater, RAUC and atomupd can then stay unmodified. This makes "install Valve's bundle directly" (PLAN.md §6.1) more realistic than UPDATES.md assumed.
- `/etc/steamos-atomupd/client.conf` points at Valve's servers with `Variants = vr` and branches `stable;rc;beta;bc;preview;pc;main`. It also contains a Valve CI login, which we never copy.
- `/boot` holds the Frame boot chain: `Image`, `maindtb.dtb`, `dtbqcom/`, `initrd.uImage`, **`kernelsetup.sh`** (writes the Frame's boot firmware via `splctl`; installed by `deckard-uboot`), `bootfw.tar.xz` and `uboot.env`. None of it applies to the Q6A.

## Frame-only services enabled by default (mask list v0)

The ones enabled out of the box (`/etc/systemd/system/*.wants/`):

| Unit | Does | On the Q6A |
|---|---|---|
| `deckard-charger`, `deckard-power-monitor` | Battery/charger | Mask |
| `deckard-audio-setup` | Frame audio routing | Mask; replace with Q6A UCM |
| `deckard-boot-images` | Pre-distorts boot images for the lenses | Mask |
| `deckard-fan-control` | Frame fan | Mask; replace with `q6a-tuned` |
| `deckard-fpga`, `deckard-fpga-resume` | Display FPGA | Mask |
| `deckard-led-control`, `deckard-typec-logger` | Frame LEDs, USB-C logging | Mask |
| `steamvr-program-ble`, `steamvr-v4l2loopback`, `steamvr-set-kernel-thread-priorities` | VR radio, passthrough cameras, VR thread priorities | Mask |
| `adbd*`, `usb-gadget*` | Android debug bridge / USB gadget | Mask |

Plus the user units `steamvr-logs`, `steamvr-plasma` and `steamvr-proxmicmute`, and the `steamvr.service` dependency of the gamescope session (GAMESCOPE.md §1).

## How to refresh this page

```
python3 tools/fetch-valve-rootfs.py --out /var/lib/q6a-test/valve-rootfs   # or Stage 2
```

Then mount `rootfs.img` read-only and repeat the checks above. Stage 2's `logs/inventory.txt` and `S2.04` collect the main ones automatically.
