#!/usr/bin/env bash
# Install the packages the test stages use (Armbian / Debian trixie, arm64).
# Safe to re-run. Packages that don't exist on this release are skipped.
set -u
if [[ $EUID -ne 0 ]]; then
  echo "Please run with sudo:  sudo $0" >&2
  exit 1
fi

PKGS=(
  # system info
  dmidecode pciutils usbutils nvme-cli util-linux lsof
  # display and GPU
  vulkan-tools mesa-vulkan-drivers mesa-utils libdrm-tests edid-decode vkmark kmscube
  # audio, network, bluetooth
  alsa-utils bluez network-manager iw curl
  # CPU load
  stress-ng
  # Stage 2: Valve image download and inspection
  python3 python3-zstandard openssl squashfs-tools btrfs-progs file
)

echo "==> Updating package lists"
apt-get update -q || { echo "apt-get update failed: check the network" >&2; exit 1; }

missing=()
for p in "${PKGS[@]}"; do
  if apt-cache show "$p" >/dev/null 2>&1; then
    missing+=("$p")
  else
    echo "    (skipping $p: not available on this release)"
  fi
done
echo "==> Installing ${#missing[@]} packages"
DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "${missing[@]}"
echo "==> Done"
