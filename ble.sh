#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/akinomyoga/ble.sh.git"
MODE="--menu"
TARGET_USER=""
NO_RESTART=0
TARGETS_DONE=()

log() { echo "[ble-installer] $*"; }
die() { echo "[ble-installer] ERROR: $*" >&2; exit 1; }

usage() {
  cat <<'EOF_USAGE'
Usage:
  bash ble.sh
  bash ble.sh --menu
  bash ble.sh --auto
  bash ble.sh --user
  bash ble.sh --root
  bash ble.sh --both
  bash ble.sh --target USER
  bash ble.sh --remove-current
  bash ble.sh --no-restart

Examples:
  bash <(curl -Ls https://raw.githubusercontent.com/Kelthuzer/color_termial/main/ble.sh)
  bash <(curl -Ls https://raw.githubusercontent.com/Kelthuzer/color_termial/main/ble.sh) --user
  sudo bash <(curl -Ls https://raw.githubusercontent.com/Kelthuzer/color_termial/main/ble.sh) --root
  sudo bash <(curl -Ls https://raw.githubusercontent.com/Kelthuzer/color_termial/main/ble.sh) --both
  sudo bash <(curl -Ls https://raw.githubusercontent.com/Kelthuzer/color_termial/main/ble.sh) --both --no-restart
EOF_USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --menu|--auto|--user|--root|--both|--remove-current)
      MODE="$1"; shift ;;
    --target)
      [ "$#" -ge 2 ] || die "Missing username after --target"
      MODE="--target"; TARGET_USER="$2"; shift 2 ;;
    --target=*)
      MODE="--target"; TARGET_USER="${1#--target=}"; shift ;;
    --no-restart)
      NO_RESTART=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      usage; die "Unknown argument: $1" ;;
  esac
done

need_cmd() { command -v "$1" >/dev/null 2>&1; }
user_exists() { getent passwd "$1" >/dev/null 2>&1; }
get_home() { getent passwd "$1" | cut -d: -f6; }
get_group() { id -gn "$1"; }

read_tty() {
  local prompt="$1"
  local varname="$2"

  if [ -r /dev/tty ]; then
    printf "%s" "$prompt" > /dev/tty
    IFS= read -r "$varname" < /dev/tty
  else
    printf "%s" "$prompt"
    IFS= read -r "$varname"
  fi
}

as_user() {
  local user="$1"
  shift

  if [ "$(id -u)" -eq 0 ] && [ "$user" != "root" ]; then
    runuser -u "$user" -- "$@"
  else
    "$@"
  fi
}

detect_normal_user() {
  if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ] && user_exists "$SUDO_USER"; then
    echo "$SUDO_USER"
    return 0
  fi

  awk -F: '($3 >= 1000 && $3 < 65534 && $6 ~ /^\/home\//) {print $1; exit}' /etc/passwd
}

install_deps_root() {
  if need_cmd apt; then
    export DEBIAN_FRONTEND=noninteractive
    apt update
    apt install -y git make gawk bash-completion ca-certificates
  elif need_cmd dnf; then
    dnf install -y git make gawk bash-completion ca-certificates
  elif need_cmd yum; then
    yum install -y git make gawk bash-completion ca-certificates
  elif need_cmd pacman; then
    pacman -Sy --noconfirm git make gawk bash-completion ca-certificates
  elif need_cmd apk; then
    apk add --no-cache git make gawk bash bash-completion ca-certificates
  elif need_cmd zypper; then
    zypper --non-interactive install git make gawk bash-completion ca-certificates
  else
    die "Unsupported package manager. Install manually: git make gawk bash-completion ca-certificates"
  fi
}

install_deps() {
  local missing=0

  for cmd in git make gawk; do
    if ! need_cmd "$cmd"; then
      missing=1
    fi
  done

  if [ "$missing" -eq 0 ]; then
    log "Dependencies already installed"
    return 0
  fi

  if [ "$(id -u)" -eq 0 ]; then
    install_deps_root
    return 0
  fi

  if need_cmd sudo; then
    log "Installing dependencies via sudo"
    sudo bash -c '
      set -e
      if command -v apt >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt update
        apt install -y git make gawk bash-completion ca-certificates
      elif command -v dnf >/dev/null 2>&1; then
        dnf install -y git make gawk bash-completion ca-certificates
      elif command -v yum >/dev/null 2>&1; then
        yum install -y git make gawk bash-completion ca-certificates
      elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm git make gawk bash-completion ca-certificates
      elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache git make gawk bash bash-completion ca-certificates
      elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install git make gawk bash-completion ca-certificates
      else
        echo "Unsupported package manager" >&2
        exit 1
      fi
    '
  else
    die "Missing dependencies and no sudo. Install manually: git make gawk bash-completion ca-certificates"
  fi
}

clean_bashrc_blesh() {
  local bashrc="$1"
  local tmp="${bashrc}.tmp.$$"

  [ -f "$bashrc" ] || touch "$bashrc"

  awk '
    BEGIN {skip=0}
    /^# >>> ble\.sh >>>$/ {skip=1; next}
    /^# <<< ble\.sh <<<$/{skip=0; next}
    skip {next}
    /blesh\/ble\.sh/ {next}
    {print}
  ' "$bashrc" > "$tmp"

  cat "$tmp" > "$bashrc"
  rm -f "$tmp"
}

append_bashrc_blesh() {
  local bashrc="$1"

  cat >> "$bashrc" <<'EOF_BLE_BLOCK'

# >>> ble.sh >>>
if [[ $- == *i* && -r "$HOME/.local/share/blesh/ble.sh" ]]; then
  source "$HOME/.local/share/blesh/ble.sh"
fi

# Re-apply Kel color terminal after ble.sh
if [[ $- == *i* && -r /etc/profile.d/99-kel-color-terminal.sh ]]; then
  source /etc/profile.d/99-kel-color-terminal.sh
fi
# <<< ble.sh <<<
EOF_BLE_BLOCK
}

install_for_user() {
  local user="$1"
  local home
  local group
  local prefix
  local bashrc
  local build_dir

  user_exists "$user" || die "User does not exist: $user"

  home="$(get_home "$user")"
  group="$(get_group "$user")"
  prefix="$home/.local"
  bashrc="$home/.bashrc"
  build_dir="/tmp/blesh-build-${user}-$$"

  [ -n "$home" ] || die "Cannot detect home for user: $user"
  [ -d "$home" ] || die "Home directory does not exist: $home"

  log "Installing ble.sh for user: $user"
  log "Home: $home"
  log "Prefix: $prefix"

  rm -rf "$build_dir"

  as_user "$user" mkdir -p "$prefix"
  as_user "$user" git clone --recursive "$REPO_URL" "$build_dir"
  as_user "$user" make -C "$build_dir" install PREFIX="$prefix"

  clean_bashrc_blesh "$bashrc"
  append_bashrc_blesh "$bashrc"

  if [ "$(id -u)" -eq 0 ]; then
    chown "$user:$group" "$bashrc"
    chown -R "$user:$group" "$prefix" 2>/dev/null || true
  fi

  rm -rf "$build_dir"

  if [ ! -r "$prefix/share/blesh/ble.sh" ]; then
    die "Installation failed: $prefix/share/blesh/ble.sh not found"
  fi

  TARGETS_DONE+=("$user")
  log "OK: ble.sh installed for $user"
}

remove_for_user() {
  local user="$1"
  local home
  local group
  local bashrc

  user_exists "$user" || die "User does not exist: $user"

  home="$(get_home "$user")"
  group="$(get_group "$user")"
  bashrc="$home/.bashrc"

  [ -f "$bashrc" ] || {
    log "No .bashrc for $user"
    return 0
  }

  clean_bashrc_blesh "$bashrc"

  if [ "$(id -u)" -eq 0 ]; then
    chown "$user:$group" "$bashrc"
  fi

  log "Removed ble.sh loader from $bashrc"
}

current_shell_user_is_target() {
  local current_user
  local target

  current_user="$(id -un)"

  for target in "${TARGETS_DONE[@]:-}"; do
    if [ "$target" = "$current_user" ]; then
      return 0
    fi
  done

  return 1
}

restart_shell_if_needed() {
  if [ "$NO_RESTART" -eq 1 ]; then
    log "Auto restart disabled"
    log "Run manually: exec bash -l"
    return 0
  fi

  if [ "${#TARGETS_DONE[@]}" -eq 0 ]; then
    return 0
  fi

  if ! current_shell_user_is_target; then
    log "Current shell user is $(id -un), installed for: ${TARGETS_DONE[*]}"
    log "Open a new session for target user or run: exec bash -l under that user"
    return 0
  fi

  log "Restarting current Bash session..."
  exec bash -l
}

install_user_mode() {
  local user

  install_deps

  if [ "$(id -u)" -eq 0 ]; then
    user="$(detect_normal_user || true)"
    [ -n "$user" ] || die "Cannot detect normal user. Use --target USER or --root"
    install_for_user "$user"
  else
    install_for_user "$(id -un)"
  fi
}

install_root_mode() {
  [ "$(id -u)" -eq 0 ] || die "--root must be run as root"
  install_deps
  install_for_user root
}

install_both_mode() {
  local user

  [ "$(id -u)" -eq 0 ] || die "--both must be run as root"

  install_deps

  user="$(detect_normal_user || true)"
  [ -n "$user" ] || die "Cannot detect normal user. Use --target USER separately."

  install_for_user root
  install_for_user "$user"
}

install_target_mode() {
  [ -n "$TARGET_USER" ] || die "Empty target user"
  install_deps
  install_for_user "$TARGET_USER"
}

menu() {
  local choice
  local user
  local detected_user

  [ -r /dev/tty ] || die "Interactive menu requires TTY. Use --user, --root, --both or --target USER."

  while true; do
    detected_user="$(detect_normal_user 2>/dev/null || echo "not found")"

    cat >/dev/tty <<EOF_MENU

ble.sh installer

1) Install for current user ($(id -un))
2) Install for detected normal user ($detected_user)
3) Install for root
4) Install for root + detected normal user
5) Install for custom user
6) Remove ble.sh loader from current user's .bashrc
0) Exit

EOF_MENU

    read_tty "Select option: " choice

    case "$choice" in
      1)
        install_deps
        install_for_user "$(id -un)"
        break ;;
      2)
        user="$(detect_normal_user || true)"
        [ -n "$user" ] || die "Cannot detect normal user"
        install_deps
        install_for_user "$user"
        break ;;
      3)
        install_root_mode
        break ;;
      4)
        install_both_mode
        break ;;
      5)
        read_tty "Username: " user
        [ -n "$user" ] || die "Empty username"
        TARGET_USER="$user"
        install_target_mode
        break ;;
      6)
        remove_for_user "$(id -un)"
        break ;;
      0)
        exit 0 ;;
      *)
        echo "Invalid option" >/dev/tty ;;
    esac
  done
}

case "$MODE" in
  --menu) menu ;;
  --auto) install_deps; install_for_user "$(id -un)" ;;
  --user) install_user_mode ;;
  --root) install_root_mode ;;
  --both) install_both_mode ;;
  --target) install_target_mode ;;
  --remove-current) remove_for_user "$(id -un)" ;;
  *) usage; die "Unknown mode: $MODE" ;;
esac

log "Done"
restart_shell_if_needed
