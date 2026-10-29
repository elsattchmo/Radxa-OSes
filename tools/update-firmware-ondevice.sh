#!/usr/bin/env bash
# Update the Q6A's SPI boot firmware to wp_260916 from Armbian itself (no second PC needed).
#
#   sudo tools/update-firmware-ondevice.sh
#
# Only for boards that already run a "wp" firmware (2026-01-20 or newer). On those, the
# firmware flash is reachable from Linux as the qcom_scm_storage MTD device. For older
# boards, or if anything here fails, use the PC + EDL method in docs/testing/STAGE-0.md.
#
# It uses Armbian's own updater (write_uboot_platform_mtd), which backs up the whole
# flash first and reads back every image after writing. It points that updater at the
# folder where Radxa's package really installs the files (/usr/lib/edk2/radxa/qcs6490).
set -u
FW_DIR=/usr/lib/edk2/radxa/qcs6490
WANT_XBL_SHA256=a1b0e8c558636fb2f0bb5835bec6f2cff615857ec924ba0036d5bc9328683bf1  # wp_260916
LOG=/var/log/q6a-firmware-update.log

die() { echo "STOPPED: $*" >&2; echo "Nothing was written. Use the PC + EDL method instead." >&2; exit 1; }

[[ $EUID -eq 0 ]] || { echo "Please run with sudo." >&2; exit 1; }
model=$(tr -d '\0' </sys/firmware/devicetree/base/model 2>/dev/null)
[[ $model == *"Dragon Q6A"* ]] || die "this is not a Radxa Dragon Q6A (model: '$model')"

current=$(cat /sys/class/dmi/id/bios_version 2>/dev/null)
echo "Current firmware: ${current:-unknown}"
if [[ $current == *260916* ]]; then
  echo "Already on wp_260916. Nothing to do."
  exit 0
fi

mtd=""
for d in /sys/class/mtd/mtd*; do
  [[ -e $d/name && $(cat "$d/name") == qcom_scm_storage ]] && mtd=/dev/${d##*/} && break
done
[[ -n $mtd ]] || die "the firmware flash is not reachable from Linux (no qcom_scm_storage device). Your firmware is probably older than 2026-01-20, or the kernel lacks the driver."

[[ -f /usr/lib/u-boot/platform_install.sh ]] || die "Armbian's updater is missing (/usr/lib/u-boot/platform_install.sh). Is this Armbian?"
echo "Installing Radxa's firmware package and edl-ng..."
apt-get install -y -q edk2-radxa-dragon-q6a edl-ng >/dev/null || die "could not install edk2-radxa-dragon-q6a / edl-ng"
[[ -f $FW_DIR/rawprogram0.xml && -f $FW_DIR/xbl.elf ]] || die "firmware files not found in $FW_DIR"
got=$(sha256sum "$FW_DIR/xbl.elf" | cut -d' ' -f1)
[[ $got == "$WANT_XBL_SHA256" ]] || die "the packaged firmware is not the expected wp_260916 build (xbl.elf sha256 $got). The package may have been updated: ask before flashing."

echo
echo "About to write firmware wp_260916 to $mtd."
echo "Keep the power connected and don't touch the board until it says it's finished (about 5 minutes)."
read -r -p "Type YES to continue: " ok
[[ $ok == YES ]] || die "cancelled"

# shellcheck disable=SC1091
. /usr/lib/u-boot/platform_install.sh
if write_uboot_platform_mtd "$FW_DIR" "$mtd" "$LOG"; then
  cat "$LOG"
  echo
  echo "Finished. Shut down (sudo poweroff), unplug the power for 10 seconds, then power on."
else
  cat "$LOG"
  echo
  echo "The update reported a problem. Do NOT reboot. Paste the text above into the chat."
  echo "A backup of the old firmware is in /var/backups/ (spinor-*.bin)."
  exit 1
fi
