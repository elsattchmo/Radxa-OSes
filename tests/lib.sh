# shellcheck shell=bash
# Shared helpers for the q6a-test stages. Sourced, not run.
#
# Every check reports one line: PASS / FAIL / WARN / INFO / SKIP, an ID, and a message.
# Results go to the terminal and to SUMMARY.md; command output goes to logs/.

if [[ -t 1 ]]; then
  C_PASS=$'\e[32m' C_FAIL=$'\e[31m' C_WARN=$'\e[33m' C_INFO=$'\e[36m' C_SKIP=$'\e[90m' C_BOLD=$'\e[1m' C_OFF=$'\e[0m'
else
  C_PASS="" C_FAIL="" C_WARN="" C_INFO="" C_SKIP="" C_BOLD="" C_OFF=""
fi

N_PASS=0 N_FAIL=0 N_WARN=0
INTERACTIVE=${INTERACTIVE:-1}

# init_report <stage-name>: creates REPORT_DIR, LOG_DIR and SUMMARY
init_report() {
  local stage=$1 owner_home
  owner_home=$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)
  REPORT_ROOT=${REPORT_ROOT:-${owner_home:-/root}/q6a-reports}
  REPORT_DIR="$REPORT_ROOT/$stage-$(date +%Y%m%d-%H%M%S)"
  LOG_DIR="$REPORT_DIR/logs"
  SUMMARY="$REPORT_DIR/SUMMARY.md"
  mkdir -p "$LOG_DIR"
  {
    echo "# q6a-test $stage"
    echo
    echo "- Date: $(date -Is)"
    echo "- Host: $(hostname)  Kernel: $(uname -r)"
    echo "- Repo commit: ${REPO_COMMIT:-unknown}"
    echo
    echo "| Result | ID | Check |"
    echo "|---|---|---|"
  } >"$SUMMARY"
}

section() {
  printf '\n%s== %s ==%s\n' "$C_BOLD" "$1" "$C_OFF"
}

# result <PASS|FAIL|WARN|INFO|SKIP> <id> <message>
result() {
  local status=$1 id=$2 msg=$3 color
  case $status in
    PASS) color=$C_PASS; N_PASS=$((N_PASS + 1)) ;;
    FAIL) color=$C_FAIL; N_FAIL=$((N_FAIL + 1)) ;;
    WARN) color=$C_WARN; N_WARN=$((N_WARN + 1)) ;;
    INFO) color=$C_INFO ;;
    *) color=$C_SKIP ;;
  esac
  printf '  %s%-4s%s %-7s %s\n' "$color" "$status" "$C_OFF" "$id" "$msg"
  # Keep the table intact: no pipes or newlines in the message.
  printf '| %s | %s | %s |\n' "$status" "$id" "$(tr '|\n' '/ ' <<<"$msg")" >>"$SUMMARY"
}

# logcmd <name> <command...>: run a command, save stdout+stderr to logs/<name>.txt, return its status
logcmd() {
  local name=$1
  shift
  {
    echo "\$ $*"
    "$@"
  } >"$LOG_DIR/$name.txt" 2>&1
}

have() { command -v "$1" >/dev/null 2>&1; }

# ask <question>: y/n prompt. Returns 0 for yes, 1 for no, 2 when not interactive.
ask() {
  local reply
  if [[ $INTERACTIVE != 1 || ! -t 0 ]]; then
    return 2
  fi
  while true; do
    read -r -p "  ${C_BOLD}? ${1} [y/n]${C_OFF} " reply
    case ${reply,,} in
      y | yes) return 0 ;;
      n | no) return 1 ;;
    esac
  done
}

# ask_result <id> <question> <pass message> <fail message>
ask_result() {
  local id=$1 q=$2 ok=$3 bad=$4 rc=0
  ask "$q" || rc=$?
  case $rc in
    0) result PASS "$id" "$ok" ;;
    1) result FAIL "$id" "$bad" ;;
    *) result SKIP "$id" "not asked (non-interactive run): $q" ;;
  esac
}

pause() {
  [[ $INTERACTIVE == 1 && -t 0 ]] || return 0
  read -r -p "  ${C_BOLD}${1:-Press Enter to continue}${C_OFF} " _
}

# free_display: stop a desktop login screen so KMS tests can take the TV; restore_display undoes it.
STOPPED_DM=""
free_display() {
  local dm
  for dm in gdm gdm3 sddm lightdm display-manager; do
    if systemctl is-active --quiet "$dm" 2>/dev/null; then
      echo "  Stopping the desktop ($dm) so the test can use the TV; it restarts afterwards."
      systemctl stop "$dm" && STOPPED_DM=$dm
      sleep 2
      return
    fi
  done
}
restore_display() {
  if [[ -n $STOPPED_DM ]]; then
    systemctl start "$STOPPED_DM" 2>/dev/null
    STOPPED_DM=""
  fi
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Please run with sudo:  sudo $0 $*" >&2
    exit 1
  fi
}

finish_report() {
  local tarball
  {
    echo
    echo "**Totals:** $N_PASS pass, $N_FAIL fail, $N_WARN warn"
  } >>"$SUMMARY"
  tarball="$REPORT_DIR.tar.gz"
  tar -C "$(dirname "$REPORT_DIR")" -czf "$tarball" "$(basename "$REPORT_DIR")"
  if [[ -n ${SUDO_USER:-} ]]; then
    chown -R "$SUDO_USER": "$REPORT_ROOT" 2>/dev/null || true
  fi
  printf '\n%s== Done: %d pass, %d fail, %d warn ==%s\n' "$C_BOLD" "$N_PASS" "$N_FAIL" "$N_WARN" "$C_OFF"
  echo "  Summary: $SUMMARY"
  echo "  Full report (send this): $tarball"
  echo
  echo "  Paste the summary below into the chat, or attach the .tar.gz file."
  echo "  ------------------------------------------------------------------"
  cat "$SUMMARY"
}
