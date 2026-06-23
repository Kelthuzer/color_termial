#!/usr/bin/env bash
set -Eeuo pipefail

MODE="${1:-auto}"
REPO_URL="https://github.com/akinomyoga/ble.sh.git"

log() {
  echo "[ble-installer] $*"
}

die() {
  echo "[ble-installer] ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  bash ble.sh --user
  bash ble.sh --root
  bash ble.sh --both
  bash ble.sh --auto

Modes:
  --user    install ble.sh for current non-root user
  --root    install ble.sh for root
  --both    install ble.sh for root and detected normal user
  --auto    if root: root only; if non-root: current user

Run from GitHub:
  bash <(curl -Ls https://raw.githubusercontent.com/Kelthuzer/color_termial/main/ble.sh) --user
  bash <(curl -Ls https://raw.githubusercontent.com/Kelthuzer/color_termial/main/ble.sh) --root
  bash <(curl -Ls https://raw.githubusercontent.com/Kelthuzer/color_termial/main/ble.sh) --both
EOF
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1
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

get_home() {
  local user="$1"
  getent passwd "$user" | cut -d: -f6
}

detect_normal_user() {
  if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    echo "$SUDO_USER"
    return 0
  fi

  awk -F: '($3 >= 1000 && $3 < 65534 && $6 ~ /^\/home\//) {print $1; exit}' /etc/passwd
}

install_deps_apt() {
  export DEBIAN_FRONTEND=noninteractive
  apt update
  apt install -y git make gawk bash-completion ca-certificates
}

install_deps_dnf() {
  dnf install -y git make gawk bash-completion ca-certificates
}

install_deps_yum() {
  yum install -y git make gawk bash-completion ca-certificates
}

install_deps_pacman() {
  pacman -Sy --noconfirm git make gawk bash-completion ca-certificates
}

install_deps_apk() {
  apk add --no-cache git make gawk bash bash-completion ca-certificates
}

install_deps_zypper() {
  zypper --non-interactive install git make gawk bash-completion ca-certificates
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

  if [ "$(id -u)" -ne 0 ]; then
    if need_cmd sudo; then
      log "Installing dependencies via sudo"
      sudo bash -c "$(declare -f install_deps_apt install_deps_dnf install_deps_yum install_deps_pacman install_deps_apk install_deps_zypper); install_deps_root"
    else
      die "Missing dependencies and no root/sudo access. Install: git make gawk bash-completion ca-certificates"
    fi
    return 0
  fi

  install_deps_root
}

install_deps_root() {
  if need_cmd apt; then
    install_deps_apt
  elif need_cmd dnf; then
    install_deps_dnf
  elif need_cmd yum; then
    install_deps_yum
  elif need_cmd pacman; then
    install_deps_pacman
  elif need_cmd apk; then
    install_deps_apk
  elif need_cmd zypper; then
    install_deps_zypper
  else
    die "Unsupported package manager. Install manually: git make gawk bash-completion ca-certificates"
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
    /blesh\/ble\.sh/ {next}
    {if (!skip) print}
  ' "$bashrc" > "$tmp"

  cat "$tmp" > "$bashrc"
  rm -f "$tmp"
}

append_bashrc_blesh() {
  local bashrc="$1"

  cat >> "$bashrc" <<'EOF'

# >>> ble.sh >>>
if [[ $- == *i* && -r "$HOME/.local/share/blesh/ble.sh" ]]; then
  source "$HOME/.local/share/blesh/ble.sh"
fi
# <<< ble.sh <<<
EOF
}

install_for_user() {
  local user="$1"
  local home
  local build_dir
  local prefix
  local bashrc

  home="$(get_home "$user")"
  [ -n "$home" ] || die "Cannot detect home for user: $user"
  [ -d "$home" ] || die "Home directory does not exist for user $user: $home"

  prefix="$home/.local"
  bashrc="$home/.bashrc"
  build_dir="/tmp/blesh-build-${user}-$$"

  log "Installing ble.sh for user: $user"
  log "Home: $home"
  log "Prefix: $prefix"

  rm -rf "$build_dir"

  as_user "$user" git clone --recursive "$REPO_URL" "$build_dir"
  as_user "$user" make -C "$build_dir" install PREFIX="$prefix"

  clean_bashrc_blesh "$bashrc"
  append_bashrc_blesh "$bashrc"

  if [ "$(id -u)" -eq 0 ]; then
    chown "$user:$user" "$bashrc"
    chown -R "$user:$user" "$prefix/share/blesh" "$prefix/share/blesh" 2>/dev/null || true
  fi

  rm -rf "$build_dir"

  if [ -r "$prefix/share/blesh/ble.sh" ]; then
    log "OK: ble.sh installed for $user"
  else
    die "Installation failed for $user: $prefix/share/blesh/ble.sh not found"
  fi
}

main() {
  case "$MODE" in
    -h|--help|help)
      usage
      exit 0
      ;;
    --user|user)
      install_deps

      if [ "$(id -u)" -eq 0 ]; then
        normal_user="$(detect_normal_user || true)"
        [ -n "${normal_user:-}" ] || die "Cannot detect normal user. Run as that user or use --root"
        install_for_user "$normal_user"
      else
        install_for_user "$(id -un)"
      fi
      ;;
    --root|root)
      [ "$(id -u)" -eq 0 ] || die "--root must be run as root"
      install_deps
      install_for_user root
      ;;
    --both|both)
      [ "$(id -u)" -eq 0 ] || die "--both must be run as root"
      install_deps

      normal_user="$(detect_normal_user || true)"
      [ -n "${normal_user:-}" ] || die "Cannot detect normal user. Start with sudo from user session or create a normal user first."

      install_for_user root
      install_for_user "$normal_user"
      ;;
    --auto|auto|"")
      install_deps

      if [ "$(id -u)" -eq 0 ]; then
        install_for_user root
      else
        install_for_user "$(id -un)"
      fi
      ;;
    *)
      usage
      die "Unknown mode: $MODE"
      ;;
  esac

  log "Done"
  log "Restart shell with: exec bash"
}

main "$@"
