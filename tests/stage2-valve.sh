#!/usr/bin/env bash
# Stage 2: Valve's Steam Frame SteamOS on this board, and Valve's gamescope on the TV.
#
#   sudo ./q6a-test stage2            download + verify Valve's image, run the checks (asks questions)
#   sudo ./q6a-test stage2 --auto     same, without questions
#   sudo ./q6a-test stage2-cleanup    unmount the image  (add --delete to remove the ~8 GB download)
#
# Nothing is installed or changed outside /var/lib/q6a-test and /mnt/q6a-valve. Valve's image is
# mounted read-only and used through chroot.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/lib.sh
. "$HERE/lib.sh"

WORK=${Q6A_WORK:-/var/lib/q6a-test}
MNT=/mnt/q6a-valve
R=$MNT
CHANNEL=stable
CLEANUP=0 DELETE=0
for a in "$@"; do
  case $a in
    --auto) INTERACTIVE=0 ;;
    --cleanup) CLEANUP=1 ;;
    --delete) DELETE=1 ;;
    --rc) CHANNEL=rc ;;
  esac
done

require_root "$@"

unmount_all() {
  if mountpoint -q "$MNT"; then
    umount -R "$MNT" 2>/dev/null || umount -R -l "$MNT"
  fi
}

if [[ $CLEANUP == 1 ]]; then
  unmount_all
  echo "Unmounted $MNT."
  if [[ $DELETE == 1 ]]; then
    rm -rf "${WORK:?}/valve-rootfs"
    echo "Deleted the downloaded Valve image."
  fi
  exit 0
fi

init_report stage2
trap 'restore_display; unmount_all' EXIT

# ---------------------------------------------------------------- download and verify
section "Download and verify Valve's image"
missing=""
for t in python3 openssl unsquashfs blkid chroot; do have "$t" || missing+=" $t"; done
python3 -c 'import zstandard' 2>/dev/null || missing+=" python3-zstandard"
if [[ -n $missing ]]; then
  result FAIL S2.01 "Missing tools:$missing (run: sudo ./q6a-test deps)"
  finish_report
  exit 1
fi
mkdir -p "$WORK"
avail_gb=$(df -BG --output=avail "$WORK" | tail -1 | tr -dc 0-9)
have_image=$(find "$WORK/valve-rootfs" -name rootfs.img.verified 2>/dev/null | head -1)
if ((avail_gb < 15)) && [[ -z $have_image ]]; then
  result FAIL S2.01 "Only ${avail_gb} GB free in $WORK (need 15 GB)"
  finish_report
  exit 1
fi
result PASS S2.01 "Tools present, ${avail_gb} GB free"

echo "  Downloading Valve's image (about 4.4 GB; 10–30 minutes). It resumes if interrupted."
python3 "$HERE/../tools/fetch-valve-rootfs.py" --channel "$CHANNEL" --out "$WORK/valve-rootfs" 2>&1 |
  tee "$LOG_DIR/fetch.txt"
fetch_rc=${PIPESTATUS[0]}
img=$(tail -1 "$LOG_DIR/fetch.txt")
if [[ $fetch_rc -ne 0 || ! -f $img || ! -f $img.verified ]]; then
  result FAIL S2.02 "Download or verification failed (see logs/fetch.txt)"
  finish_report
  exit 1
fi
build=$(basename "$(dirname "$img")")
cp "$(dirname "$img")"/{info.json,manifest.raucm} "$LOG_DIR/" 2>/dev/null
result PASS S2.02 "Valve build $build: signature, every chunk and the image sha256 verified"

# ---------------------------------------------------------------- mount
section "Mount Valve's image (read-only)"
unmount_all
mkdir -p "$MNT"
fstype=$(blkid -o value -s TYPE "$img")
if ! mount -o ro,loop -t "$fstype" "$img" "$MNT" 2>"$LOG_DIR/mount.txt"; then
  result FAIL S2.03 "Could not mount the $fstype image (see logs/mount.txt)"
  finish_report
  exit 1
fi
# What a program inside needs: devices, proc/sys, udev's database, and writable scratch space.
mount --rbind /dev "$R/dev" && mount --make-rslave "$R/dev"
mount -t proc proc "$R/proc"
mount --rbind /sys "$R/sys" && mount --make-rslave "$R/sys"
for d in tmp run var; do mount -t tmpfs -o mode=1777 "q6a-$d" "$R/$d"; done
mkdir -p "$R/run/udev" "$R/run/user/0" "$R/tmp/home" "$R/var/tmp"
chmod 700 "$R/run/user/0"
mount --bind /run/udev "$R/run/udev"
result PASS S2.03 "Mounted ($fstype) at $MNT"

inroot() {
  chroot "$R" /usr/bin/env -i PATH=/usr/bin:/usr/local/bin HOME=/tmp/home LANG=C.UTF-8 \
    XDG_RUNTIME_DIR=/run/user/0 "$@"
}

# ---------------------------------------------------------------- identity
grep -E '^(NAME|VERSION_ID|BUILD_ID|VARIANT_ID|VERSION_CODENAME)=' "$R/etc/os-release" >"$LOG_DIR/os-release.txt" 2>/dev/null
pkgdb=""
for d in "$R/usr/lib/holo/pacmandb/local" "$R/var/lib/pacman/local"; do [[ -d $d ]] && pkgdb=$d && break; done
if [[ -n $pkgdb ]]; then
  ls "$pkgdb" >"$LOG_DIR/packages.txt"
  pv() { grep -m1 -E "^$1-[0-9]" "$LOG_DIR/packages.txt" | sed -E "s/^$1-//"; }
  kpkg=$(grep -m1 -E '^linux-[0-9]+-deckard-[0-9]' "$LOG_DIR/packages.txt")
  result INFO S2.04 "$(tr '\n' ' ' <"$LOG_DIR/os-release.txt")| gamescope $(pv gamescope), mesa $(pv deckard-mesa-linux-aarch64), Valve kernel ${kpkg:-?}"
else
  result INFO S2.04 "$(tr '\n' ' ' <"$LOG_DIR/os-release.txt")(package list not found)"
fi

# ---------------------------------------------------------------- CPU compatibility
section "Do Valve's programs run on the Q6A's CPU?"
sigill=() ran=() notrun=()
check_bin() {
  local bin=$1
  shift
  [[ -x $R$bin ]] || return 0
  inroot timeout 20 "$bin" "$@" >>"$LOG_DIR/cpu-compat.txt" 2>&1
  local rc=$?
  echo "$bin $* -> exit $rc" >>"$LOG_DIR/cpu-compat.txt"
  if ((rc == 126 || rc == 127)); then
    notrun+=("${bin##*/}")
  else
    ran+=("${bin##*/}")
  fi
  ((rc == 132)) && sigill+=("${bin##*/}")
}
check_bin /usr/bin/bash -c true
check_bin /usr/bin/python3 -c 'import ssl, json, sqlite3'
check_bin /usr/bin/gamescope --help
check_bin /usr/bin/Xwayland -version
check_bin /usr/bin/pipewire --version
check_bin /usr/bin/vkcube --help
check_bin /usr/bin/modetest -h
check_bin /usr/bin/vulkaninfo --help
check_bin /usr/bin/kwin_wayland --version
check_bin /usr/bin/steamos-manager --help
check_bin /usr/bin/mangoapp --help
if ((${#sigill[@]})); then
  result FAIL S2.05 "Illegal instruction (program built for a newer CPU) in: ${sigill[*]}"
elif ((${#ran[@]} == 0)); then
  result FAIL S2.05 "None of Valve's programs could be started (${notrun[*]}): see logs/cpu-compat.txt"
else
  result PASS S2.05 "No illegal-instruction crashes in ${#ran[@]} programs (${ran[*]})"
fi

# ---------------------------------------------------------------- Valve's Vulkan driver
section "Valve's Vulkan driver on the Adreno 643"
icd=$(ls "$R"/usr/share/vulkan/icd.d/freedreno_icd.aarch64.json 2>/dev/null || ls "$R"/usr/share/vulkan/icd.d/*freedreno*aarch64*.json 2>/dev/null | head -1)
icd_in=${icd#"$R"}
if [[ -z $icd ]]; then
  result FAIL S2.06 "No aarch64 freedreno (Turnip) driver manifest in Valve's image"
else
  if [[ -x $R/usr/bin/vulkaninfo ]]; then
    inroot VK_DRIVER_FILES="$icd_in" VK_ICD_FILENAMES="$icd_in" vulkaninfo --summary >"$LOG_DIR/valve-vulkaninfo.txt" 2>&1
    how="Valve's vulkaninfo"
  elif have vulkaninfo; then
    # Load Valve's driver into the host's vulkaninfo through a manifest pointing into the image.
    lib=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ICD"]["library_path"])' "$icd")
    [[ $lib == /* ]] || lib=/usr/lib/$lib
    python3 - "$icd" "$R$lib" >"$WORK/valve-icd.json" <<'EOF'
import json, sys
m = json.load(open(sys.argv[1]))
m["ICD"]["library_path"] = sys.argv[2]
print(json.dumps(m))
EOF
    VK_DRIVER_FILES="$WORK/valve-icd.json" VK_ICD_FILENAMES="$WORK/valve-icd.json" \
      vulkaninfo --summary >"$LOG_DIR/valve-vulkaninfo.txt" 2>&1
    how="host vulkaninfo + Valve's driver"
  fi
  dev=$(grep -m1 deviceName "$LOG_DIR/valve-vulkaninfo.txt" 2>/dev/null | cut -d= -f2- | xargs)
  drv=$(grep -m1 driverInfo "$LOG_DIR/valve-vulkaninfo.txt" 2>/dev/null | cut -d= -f2- | xargs)
  api=$(grep -m1 apiVersion "$LOG_DIR/valve-vulkaninfo.txt" 2>/dev/null | cut -d= -f2- | xargs)
  if [[ $dev == *Adreno* ]]; then
    result PASS S2.06 "Valve's Turnip ($drv) drives: $dev, Vulkan $api [$how]"
  else
    result FAIL S2.06 "Valve's Turnip did not find the GPU (${dev:-no device}; see logs/valve-vulkaninfo.txt) [$how]"
  fi
fi

# ---------------------------------------------------------------- gamescope on the TV
section "Valve's gamescope on the TV"
conn=""
for c in /sys/class/drm/card*-*; do
  [[ $(cat "$c/status" 2>/dev/null) == connected ]] && conn=${c##*/} && conn=${conn#card*-} && break
done
client=()
if [[ -x $R/usr/bin/vkcube ]]; then
  if inroot vkcube --help 2>&1 | grep -q -- '--wsi'; then client=(vkcube --wsi xcb); else client=(vkcube); fi
else
  for c in glxgears eglgears_x11 es2gears_x11 xeyes xterm; do
    [[ -x $R/usr/bin/$c ]] && client=("$c") && break
  done
fi
if [[ -z $conn ]]; then
  result FAIL S2.07 "No TV connected"
elif ((${#client[@]} == 0)); then
  result SKIP S2.07 "No test program (vkcube/glxgears/…) in Valve's image; gamescope tests need one (tell Claude)"
else
  free_display
  echo "  Each test shows '${client[*]}' through gamescope on the TV for about 20 seconds."
  echo "  Watch the TV, then answer the question that follows."
  gsn=0
  gs_run() { # gs_run <id> <question> <ok msg> <bad msg> <gamescope args...>
    local id=$1 q=$2 ok=$3 bad=$4 log
    shift 4
    gsn=$((gsn + 1))
    log="$LOG_DIR/gamescope-$gsn-$id.txt"
    echo "  [$id] gamescope $*"
    inroot LIBSEAT_BACKEND=noop VK_DRIVER_FILES="$icd_in" VK_ICD_FILENAMES="$icd_in" \
      timeout -s INT -k 5 25 gamescope --backend drm -O "$conn" "$@" -- "${client[@]}" >"$log" 2>&1
    local errs
    errs=$(grep -c -i -E 'error|failed|EINVAL' "$log")
    echo "       (log: $(basename "$log"), $errs error lines)"
    ask_result "$id" "$q" "$ok" "$bad ($errs error lines in $(basename "$log"))"
  }
  pause "Press Enter to start the first gamescope test"
  gs_run S2.07 "Did the TV show the test animation full-screen?" \
    "Valve's gamescope drives the TV over KMS (G0)" "No picture from gamescope" \
    -W 1920 -H 1080 -w 1920 -h 1080 --debug-layers
  gs_run S2.08 "Same test with forced composition: did it look the same (no flicker or corruption)?" \
    "Composited output OK" "Composited output looked wrong" \
    -W 1920 -H 1080 -w 1920 -h 1080 --force-composition
  gs_run S2.09 "720p scaled to 1080p: did it look clean, with no flicker?" \
    "720p→1080p scaling OK (G4)" "Scaling flickered or failed (G4)" \
    -W 1920 -H 1080 -w 1280 -h 720 -S fit -F linear --debug-layers
  if inroot gamescope --help 2>&1 | grep -q sgsr; then up=sgsr; else up=fsr; fi
  gs_run S2.10 "${up^^} upscaling 720p→1080p: did it look sharp and smooth?" \
    "${up^^} upscaling OK" "${up^^} upscaling looked wrong" \
    -W 1920 -H 1080 -w 1280 -h 720 -F "$up"
  [[ $up == fsr ]] && result INFO S2.10b "This gamescope build has no SGSR upscaler (added upstream in 3.16.30); FSR tested instead"
  if [[ -x /usr/bin/modetest || -x /usr/sbin/modetest ]] && modetest -M msm -c 2>/dev/null | grep -qE '^\s+#[0-9]+ 1920x1080 1(19|20)\.'; then
    gs_run S2.11 "120 Hz mode: did the picture appear (check your TV's info banner says 120 Hz if it can)?" \
      "1080p120 output works" "1080p120 output failed" \
      -W 1920 -H 1080 -w 1920 -h 1080 -r 120
  else
    result SKIP S2.11 "TV doesn't offer 1080p at 120 Hz (or modetest missing)"
  fi
  restore_display
fi

# ---------------------------------------------------------------- FEX and Lepton pieces in the OS
section "x86 (FEX) and Android (Lepton) support files"
# On the Frame, FEX itself is a Steam tool (steamapps/common/FEX-Emu) downloaded by Steam, like Proton,
# so it can only be tested once Steam runs (Stage 3). The OS ships the x86 graphics driver for it.
if [[ -e $R/usr/share/guestos/fex-mesa/usr/lib/ld-linux-x86-64.so.2 ]]; then
  result PASS S2.12 "x86 Mesa for FEX guests present (/usr/share/guestos/fex-mesa); FEX itself arrives through Steam (Stage 3)"
else
  result WARN S2.12 "No x86 Mesa for FEX guests found in /usr/share/guestos/fex-mesa"
fi
if [[ -d $R/usr/share/guestos/android ]]; then
  result INFO S2.12b "Android (Lepton) guest files present (/usr/share/guestos/android)"
fi

# ---------------------------------------------------------------- inventory for the planning work
{
  echo "## Frame-only and VR units in the image"
  find "$R/usr/lib/systemd" "$R/etc/systemd" -name '*.service' 2>/dev/null |
    grep -i -E 'steamvr|vr|fpga|adb|gadget|deckard|tracking|camera|power-?monitor' | sed "s|$R||" | sort
  echo
  echo "## Gamescope session"
  ls -l "$R/usr/lib/steamos/" 2>/dev/null
} >"$LOG_DIR/inventory.txt"
result INFO S2.13 "Saved an inventory of Frame/VR services and session files (logs/inventory.txt)"

finish_report
