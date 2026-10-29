#!/usr/bin/env bash
# Stage 1: hardware baseline on Armbian. Read-only except for short test tones,
# a GPU test on the TV and an optional 60-second CPU stress run.
#
#   sudo ./q6a-test stage1            (interactive: asks what you see and hear)
#   sudo ./q6a-test stage1 --auto     (no questions, no tones, no stress run)
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/lib.sh
. "$HERE/lib.sh"

RECOMMENDED_FW=260916       # docs/FIRMWARE.md
MIN_KERNEL=7.2              # Armbian edge
QUICK=0
for a in "$@"; do
  case $a in
    --auto) INTERACTIVE=0; QUICK=1 ;;
    --quick) QUICK=1 ;;
  esac
done

require_root "$@"
init_report stage1

# ---------------------------------------------------------------- system
section "Firmware and kernel"
for f in bios_vendor bios_version bios_date board_name product_name; do
  echo "$f: $(cat /sys/class/dmi/id/$f 2>/dev/null)"
done >"$LOG_DIR/dmi.txt"
have dmidecode && logcmd dmidecode-bios dmidecode -t bios -t system
fwv=$(cat /sys/class/dmi/id/bios_version 2>/dev/null)
fwd=$(cat /sys/class/dmi/id/bios_date 2>/dev/null)
fwdate=""
if [[ $fwv =~ ([0-9]{6})\.BOOT ]]; then
  fwdate=${BASH_REMATCH[1]}
elif [[ $fwd =~ ^([0-9]{2})/([0-9]{2})/[0-9]{2}([0-9]{2})$ ]]; then
  fwdate=${BASH_REMATCH[3]}${BASH_REMATCH[1]}${BASH_REMATCH[2]}
fi
if [[ -z $fwdate ]]; then
  result WARN S1.01 "Firmware version not recognised (bios_version='$fwv', bios_date='$fwd')"
elif ((10#$fwdate >= RECOMMENDED_FW)); then
  result PASS S1.01 "Firmware $fwdate (recommended $RECOMMENDED_FW or newer) [$fwv]"
else
  result WARN S1.01 "Firmware $fwdate is older than $RECOMMENDED_FW: update it (docs/testing/STAGE-0.md, step 3) [$fwv]"
fi

kver=$(uname -r)
if [[ $(printf '%s\n%s\n' "$MIN_KERNEL" "${kver%%-*}" | sort -V | head -1) == "$MIN_KERNEL" ]]; then
  result PASS S1.02 "Kernel $kver"
else
  result WARN S1.02 "Kernel $kver is older than $MIN_KERNEL: sudo apt install linux-image-edge-qcs6490 linux-dtb-edge-qcs6490, then reboot"
fi
logcmd cmdline cat /proc/cmdline
logcmd dmesg dmesg

rootsrc=$(findmnt -no SOURCE / 2>/dev/null)
if [[ $rootsrc == /dev/nvme* ]]; then
  result PASS S1.03 "Running from NVMe ($rootsrc)"
else
  result WARN S1.03 "Running from $rootsrc, not NVMe (docs/testing/STAGE-0.md, step 5)"
fi

if [[ -d /sys/firmware/efi ]]; then
  nvars=$(find /sys/firmware/efi/efivars -maxdepth 1 -type f 2>/dev/null | wc -l)
  if ((nvars > 0)); then
    result PASS S1.04 "Booted by UEFI; $nvars EFI variables readable"
  else
    result WARN S1.04 "Booted by UEFI, but EFI variables are not available (needs the QSEECOM allowlist patch: Armbian edge has it)"
  fi
  logcmd efivars ls -l /sys/firmware/efi/efivars
else
  result FAIL S1.04 "Not booted through UEFI"
fi

mtd=""
for d in /sys/class/mtd/mtd*; do
  [[ -e $d/name ]] || continue
  echo "$(basename "$d"): $(cat "$d/name")"
  [[ $(cat "$d/name") == qcom_scm_storage ]] && mtd=/dev/$(basename "$d")
done >"$LOG_DIR/mtd.txt"
if [[ -n $mtd ]]; then
  result INFO S1.05 "Firmware flash reachable from Linux ($mtd, qcom_scm_storage): on-device firmware updates possible"
else
  result INFO S1.05 "Firmware flash not reachable from Linux: update firmware from a PC in EDL mode"
fi

# ---------------------------------------------------------------- memory and storage
section "Memory and storage"
memtotal=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
logcmd meminfo cat /proc/meminfo
dmesg | grep -i -E 'reserved mem|Memory:|cma' >"$LOG_DIR/reserved-memory.txt" 2>&1
board_mib=0
for size in 4096 6144 8192 12288 16384; do
  if ((memtotal <= size)); then board_mib=$size; break; fi
done
if ((board_mib > 0)); then
  result INFO S1.06 "MemTotal ${memtotal} MiB of a ${board_mib} MiB board: firmware + kernel keep $((board_mib - memtotal)) MiB"
else
  result INFO S1.06 "MemTotal ${memtotal} MiB"
fi

nvme=$(lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$1 ~ /^nvme/ && $2=="disk" {print $1; exit}')
if [[ -n $nvme ]]; then
  model=$(cat "/sys/block/$nvme/device/model" 2>/dev/null | xargs)
  result PASS S1.07 "NVMe found: /dev/$nvme ($model, $(lsblk -dn -o SIZE "/dev/$nvme"))"
  have nvme && logcmd nvme-smart nvme smart-log "/dev/$nvme"
  if have lspci; then
    logcmd lspci lspci -vv
    link=$(lspci -vv 2>/dev/null | awk '/Non-Volatile memory controller/{f=1} f && /LnkSta:/{print; exit}' | sed 's/^\s*//')
    [[ -n $link ]] && result INFO S1.08 "NVMe PCIe link: $link (expect 8GT/s, Width x2)"
  fi
  speed=$(dd if="/dev/$nvme" of=/dev/null bs=4M count=256 iflag=direct 2>&1 | awk '/copied/ {print $(NF-1), $NF}')
  result INFO S1.09 "NVMe sequential read: ${speed:-unknown} (read-only test)"
else
  result FAIL S1.07 "No NVMe drive found"
fi
avail_gb=$(df -BG --output=avail / | tail -1 | tr -dc 0-9)
if ((avail_gb >= 30)); then
  result PASS S1.10 "${avail_gb} GB free on / (Stages 2–3 need 30 GB)"
else
  result FAIL S1.10 "Only ${avail_gb} GB free on / (Stages 2–3 need 30 GB)"
fi

# ---------------------------------------------------------------- display
section "Display (HDMI)"
connected=""
for c in /sys/class/drm/card*-*; do
  [[ -e $c/status ]] || continue
  name=${c##*/}
  st=$(cat "$c/status")
  echo "$name: $st $(head -3 "$c/modes" 2>/dev/null | tr '\n' ' ')" >>"$LOG_DIR/connectors.txt"
  if [[ $st == connected ]]; then
    connected=$name
    cp "$c/edid" "$LOG_DIR/edid-$name.bin" 2>/dev/null
    have edid-decode && edid-decode "$c/edid" >"$LOG_DIR/edid-$name.txt" 2>&1
  fi
done
if [[ -n $connected ]]; then
  result PASS S1.11 "Display connected on ${connected#card*-} ($(head -1 "/sys/class/drm/$connected/modes"))"
else
  result FAIL S1.11 "No connected display found (is the TV on and on the right input?)"
fi

if have modetest; then
  logcmd modetest modetest -M msm -c
  modes=$(grep -E '^\s+#[0-9]+ [0-9]+x[0-9]+' "$LOG_DIR/modetest.txt" | awk '{printf "%s@%s\n", $2, $3}' | sort -u)
  printf '%s\n' "$modes" >"$LOG_DIR/modes-with-refresh.txt"
  hz1080=$(grep '^1920x1080@' <<<"$modes" | cut -d@ -f2 | sort -n | tail -1)
  hz4k=$(grep '^3840x2160@' <<<"$modes" | cut -d@ -f2 | sort -n | tail -1)
  result INFO S1.12 "Highest 1080p refresh offered: ${hz1080:-none} Hz; highest 4K refresh: ${hz4k:-none} Hz (Qualcomm rates the DP link at 4K30)"
else
  result SKIP S1.12 "modetest missing (run tests/install-deps.sh)"
fi

if [[ -n $connected && -s $LOG_DIR/edid-$connected.txt ]]; then
  vrr=$(grep -i -E 'VRRmin|VRRmax|FreeSync|Adaptive|Monitor ranges|Range Limits' "$LOG_DIR/edid-$connected.txt" | sed 's/^\s*//' | head -4 | tr '\n' ';')
  result INFO S1.13 "TV EDID VRR/range info: ${vrr:-none found}"
fi

aux=$(ls /dev/drm_dp_aux* 2>/dev/null | head -1)
if [[ -n $aux ]]; then
  mapfile -t d < <(dd if="$aux" bs=1 count=16 2>/dev/null | od -An -v -tx1 | tr -s ' ' '\n' | grep .)
  mapfile -t ds < <(dd if="$aux" bs=1 skip=128 count=4 2>/dev/null | od -An -v -tx1 | tr -s ' ' '\n' | grep .)
  { echo "DPCD 0x000-0x00f: ${d[*]}"; echo "DPCD 0x080-0x083: ${ds[*]}"; } >"$LOG_DIR/dpcd.txt"
  if ((${#d[@]} >= 8)); then
    rev=${d[0]} rate=$((16#${d[1]})) lanes=$((16#${d[2]} & 0x1f)) b7=$((16#${d[7]}))
    msa=$(((b7 >> 6) & 1))
    dstype=""
    if ((${#ds[@]})); then
      case $((16#${ds[0]} & 7)) in 0) dstype=DP ;; 1) dstype=VGA ;; 2) dstype=DVI ;; 3) dstype=HDMI ;; *) dstype=other ;; esac
    fi
    result INFO S1.14 "DP sink/bridge: DPCD rev $rev, max link rate $((rate * 27 / 100)).$((rate * 27 % 100)) Gbps/lane, $lanes lanes, downstream ${dstype:-unknown}"
    if ((msa)); then
      result PASS S1.15 "Bridge advertises MSA_TIMING_PAR_IGNORED: DP Adaptive-Sync is possible, so VRR is worth pursuing"
    else
      result INFO S1.15 "Bridge does not advertise MSA_TIMING_PAR_IGNORED: VRR through this bridge is very unlikely (PERFORMANCE.md §3)"
    fi
  else
    result SKIP S1.14 "Could not read DPCD from $aux"
  fi
else
  result SKIP S1.14 "No /dev/drm_dp_aux* device (kernel built without DP AUX chardev): VRR check not possible"
fi

# ---------------------------------------------------------------- GPU
section "GPU"
if have vulkaninfo; then
  logcmd vulkaninfo vulkaninfo --summary
  dev=$(grep -m1 'deviceName' "$LOG_DIR/vulkaninfo.txt" | cut -d= -f2- | xargs)
  drv=$(grep -m1 'driverInfo' "$LOG_DIR/vulkaninfo.txt" | cut -d= -f2- | xargs)
  api=$(grep -m1 'apiVersion' "$LOG_DIR/vulkaninfo.txt" | cut -d= -f2- | xargs)
  if [[ $dev == *Adreno* ]]; then
    result PASS S1.16 "Vulkan: $dev, API $api, $drv"
  else
    result FAIL S1.16 "Vulkan did not find the Adreno GPU (got '${dev:-nothing}'; see logs/vulkaninfo.txt)"
  fi
else
  result SKIP S1.16 "vulkaninfo missing (run tests/install-deps.sh)"
fi

gpufreq=$(ls -d /sys/class/devfreq/*gpu* 2>/dev/null | head -1)
if [[ -n $gpufreq ]]; then
  freqs=$(tr ' ' '\n' <"$gpufreq/available_frequencies" | grep . | awk '{printf "%d ", $1/1000000}')
  result INFO S1.17 "GPU clock steps (MHz): $freqs(governor $(cat "$gpufreq/governor"))"
fi
nvm=""
for n in /sys/bus/nvmem/devices/*; do
  [[ $(cat "$n/of_node/compatible" 2>/dev/null | tr '\0' ' ') == *qfprom* ]] && nvm=$n/nvmem && break
done
if [[ -n $nvm && -r $nvm ]]; then
  raw=$(dd if="$nvm" bs=1 skip=$((0x1e9)) count=2 2>/dev/null | od -An -tu2 | xargs)
  if [[ -n $raw ]]; then
    fuse=$(((raw >> 5) & 0xff))
    case $fuse in
      190) bin="bin 1: 840/900 MHz already enabled" ;;
      172) bin="bin 2: stock max 812 MHz; the 840/900 MHz overclock overlay targets this bin" ;;
      129) bin="bin 4: stock max 608 MHz" ;;
      0 | 117) bin="bin 0: stock max 550 MHz" ;;
      *) bin="unknown bin" ;;
    esac
    result INFO S1.18 "GPU speed-bin fuse $fuse ($bin)"
  fi
fi

if [[ -n $connected ]]; then
  free_display
  if have vkmark; then
    echo "  The TV will show a GPU test for about 20 seconds."
    timeout 90 vkmark --winsys kms -b cube:duration=10 -b shading:duration=10 >"$LOG_DIR/vkmark.txt" 2>&1
    score=$(grep -i 'vkmark Score' "$LOG_DIR/vkmark.txt" | awk '{print $NF}')
    result INFO S1.19 "vkmark score (cube + shading, 10 s each): ${score:-not produced, see logs/vkmark.txt}"
    ask_result S1.20 "Did the TV show spinning/shaded 3D scenes without flicker or corruption?" \
      "GPU renders to HDMI (Vulkan, KMS)" "GPU output to HDMI looked wrong"
  elif have kmscube; then
    timeout 15 kmscube >"$LOG_DIR/kmscube.txt" 2>&1
    ask_result S1.20 "Did the TV show a spinning cube for about 15 seconds?" \
      "GPU renders to HDMI (OpenGL ES, KMS)" "No cube on the TV"
  else
    result SKIP S1.19 "vkmark/kmscube missing (run tests/install-deps.sh)"
  fi
  restore_display
fi

# ---------------------------------------------------------------- CPU and thermals
section "CPU and thermals"
cpus=""
for p in /sys/devices/system/cpu/cpufreq/policy*; do
  [[ -e $p/cpuinfo_max_freq ]] || continue
  cpus+="${p##*policy}:$(($(cat "$p/cpuinfo_max_freq") / 1000))MHz "
done
result INFO S1.21 "CPU clusters (first CPU:max): ${cpus}governor $(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null)"

for z in /sys/class/thermal/thermal_zone*; do
  t=$(cat "$z/temp" 2>/dev/null) || continue
  echo "$(cat "$z/type"): $((t / 1000)) C"
done >"$LOG_DIR/thermal.txt"
hot=$(sort -t: -k2 -n "$LOG_DIR/thermal.txt" | tail -1)
result INFO S1.22 "$(wc -l <"$LOG_DIR/thermal.txt") thermal zones; hottest now: $hot"
fan=""
for h in /sys/class/hwmon/hwmon*; do
  [[ -e $h/pwm1 ]] && fan="$(cat "$h/name") ($h/pwm1)"
done
grep -l -i fan /sys/class/thermal/cooling_device*/type >/dev/null 2>&1 && fan=${fan:-"fan cooling device"}
if [[ -n $fan ]]; then
  result INFO S1.23 "Fan control found: $fan"
else
  result INFO S1.23 "No software-controlled fan (expected: the mainline device tree has no fan node)"
fi

if [[ $QUICK == 0 ]] && have stress-ng; then
  echo "  Running a 60-second all-core CPU load and logging temperatures and clocks..."
  stress-ng --cpu 8 --timeout 60 >/dev/null 2>&1 &
  spid=$!
  echo "time hottest_C cpu0_MHz cpu4_MHz cpu7_MHz" >"$LOG_DIR/stress.txt"
  for i in $(seq 0 5 60); do
    t=$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -n | tail -1)
    f0=$(($(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq) / 1000))
    f4=$(($(cat /sys/devices/system/cpu/cpu4/cpufreq/scaling_cur_freq) / 1000))
    f7=$(($(cat /sys/devices/system/cpu/cpu7/cpufreq/scaling_cur_freq) / 1000))
    echo "$i $((t / 1000)) $f0 $f4 $f7" >>"$LOG_DIR/stress.txt"
    sleep 5
  done
  wait "$spid" 2>/dev/null
  peak=$(awk 'NR>1 {if ($2>m) m=$2} END {print m}' "$LOG_DIR/stress.txt")
  minbig=$(awk 'NR>2 {if (m=="" || $4<m) m=$4} END {print m}' "$LOG_DIR/stress.txt")
  result INFO S1.24 "60 s CPU load: peak ${peak} C, lowest big-core clock during load ${minbig} MHz (drops = throttling)"
else
  result SKIP S1.24 "CPU stress run skipped"
fi

# ---------------------------------------------------------------- audio
section "Audio"
if have aplay; then
  logcmd aplay-l aplay -l
  logcmd aplay-L aplay -L
  cards=$(grep -c '^card' "$LOG_DIR/aplay-l.txt")
  if ((cards > 0)); then
    result PASS S1.25 "$cards playback device(s): $(grep '^card' "$LOG_DIR/aplay-l.txt" | sed -E 's/card ([0-9]+): ([^ ]+).*device ([0-9]+): ([^[]+).*/\1,\3 \2 \4/' | tr '\n' ';')"
  else
    result FAIL S1.25 "No sound playback devices"
  fi
  if [[ $INTERACTIVE == 1 && $QUICK == 0 ]] && ((cards > 0)); then
    echo "  Plug headphones into the 3.5 mm jack and turn the TV volume up."
    echo "  A 2-second test tone will play on each output in turn."
    pause "Press Enter to start the tones"
    while read -r card dev label; do
      echo "  Playing on card $card device $dev ($label)..."
      timeout 6 speaker-test -D "plughw:$card,$dev" -c 2 -t sine -f 440 -l 1 >>"$LOG_DIR/speaker-test.txt" 2>&1
      ask_result "S1.26-$card.$dev" "Did you hear a tone (headphones or TV) for: $label?" \
        "Sound works on $label" "No sound on $label"
    done < <(grep '^card' "$LOG_DIR/aplay-l.txt" | sed -E 's/card ([0-9]+): [^,]*, device ([0-9]+): ([^[]*).*/\1 \2 \3/')
  fi
else
  result SKIP S1.25 "alsa-utils missing"
fi

# ---------------------------------------------------------------- wireless and network
section "Network, Wi-Fi and Bluetooth"
if have nmcli; then
  logcmd nmcli-dev nmcli -t -f DEVICE,TYPE,STATE dev
  if grep -q ':wifi:' "$LOG_DIR/nmcli-dev.txt"; then
    nets=$(nmcli -t -f SSID dev wifi list 2>/dev/null | grep -c .)
    result PASS S1.27 "Wi-Fi adapter present; $nets networks visible"
  else
    result FAIL S1.27 "No Wi-Fi adapter (AIC8800 driver missing?)"
  fi
fi
if have bluetoothctl; then
  logcmd bt-show bluetoothctl show
  if grep -q 'Controller' "$LOG_DIR/bt-show.txt"; then
    timeout 15 bluetoothctl --timeout 12 scan on >"$LOG_DIR/bt-scan.txt" 2>&1
    found=$(grep -c 'NEW. Device' "$LOG_DIR/bt-scan.txt")
    result PASS S1.28 "Bluetooth controller present; $found devices seen in a 12 s scan"
  else
    result FAIL S1.28 "No Bluetooth controller"
  fi
fi
if curl -fsS -m 15 -o /dev/null https://steamdeck-atomupd.steamos.cloud/meta/holo/steamos/aarch64/vr/stable.json; then
  result PASS S1.29 "Internet works and Valve's update server is reachable"
else
  result FAIL S1.29 "Cannot reach Valve's update server (needed for Stage 2)"
fi
have lsusb && logcmd lsusb lsusb

finish_report
