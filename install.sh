#!/usr/bin/env bash
set -Eeuo pipefail

PROFILE_SNIPPET="/etc/profile.d/99-kel-color-terminal.sh"
TS="$(date +%Y%m%d-%H%M%S)"

log()  { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }

if [ "$(id -u)" -ne 0 ]; then
  err "Запусти от root: sudo bash install.sh"
  exit 1
fi

if [ -r /etc/os-release ]; then
  . /etc/os-release
  os_line="${ID:-unknown} ${VERSION_ID:-} ${ID_LIKE:-}"
  case " $os_line " in
    *debian*|*ubuntu*) ;;
    *) warn "ОС не похожа на Debian/Ubuntu: $os_line. Продолжаю." ;;
  esac
fi

backup_file() {
  local f="$1"
  if [ -e "$f" ] && [ ! -e "${f}.bak-${TS}" ]; then
    cp -a "$f" "${f}.bak-${TS}"
    log "Бэкап: ${f}.bak-${TS}"
  fi
}

remove_source_block() {
  local f="$1"
  local tmp

  [ -e "$f" ] || return 0
  tmp="${f}.tmp.$$"

  awk '
    BEGIN {skip=0; legacy=0}
    /^# >>> kel-color-terminal >>>$/ {skip=1; next}
    /^# <<< kel-color-terminal <<<$/{skip=0; next}
    skip {next}
    /if \[ -r \/etc\/profile\.d\/99-kel-color-terminal\.sh \]; then/ {legacy=2; next}
    legacy > 0 {legacy--; next}
    /\/etc\/profile\.d\/99-kel-color-terminal\.sh/ {next}
    {print}
  ' "$f" > "$tmp"

  cat "$tmp" > "$f"
  rm -f "$tmp"
}

append_source_block() {
  local f="$1"
  local owner="${2:-}"
  local mode="${3:-0644}"

  if [ ! -e "$f" ]; then
    install -m "$mode" /dev/null "$f"
    [ -n "$owner" ] && chown "$owner" "$f" || true
  fi

  backup_file "$f"
  remove_source_block "$f"

  cat >> "$f" <<'EOS'

# >>> kel-color-terminal >>>
if [ -r /etc/profile.d/99-kel-color-terminal.sh ]; then
  . /etc/profile.d/99-kel-color-terminal.sh
fi
# <<< kel-color-terminal <<<
EOS

  [ -n "$owner" ] && chown "$owner" "$f" || true
  chmod "$mode" "$f" || true
  log "Подключено: $f"
}

ensure_profile_sources_bashrc() {
  local profile="$1"
  local owner="${2:-}"

  if [ ! -e "$profile" ]; then
    cat > "$profile" <<'EOS'
if [ "$BASH" ]; then
  if [ -f ~/.bashrc ]; then
    . ~/.bashrc
  fi
fi
mesg n 2> /dev/null || true
EOS
    [ -n "$owner" ] && chown "$owner" "$profile" || true
    chmod 0644 "$profile" || true
    log "Создан: $profile"
    return 0
  fi

  if grep -Eq '(^|[[:space:]])\. +~/.bashrc|source +~/.bashrc|\. +\$HOME/.bashrc|source +\$HOME/.bashrc' "$profile"; then
    return 0
  fi

  backup_file "$profile"
  cat >> "$profile" <<'EOS'

if [ "$BASH" ]; then
  if [ -f ~/.bashrc ]; then
    . ~/.bashrc
  fi
fi
EOS
  [ -n "$owner" ] && chown "$owner" "$profile" || true
  log "Добавлено подключение ~/.bashrc в $profile"
}

repair_existing_blesh_block() {
  local bashrc="$1"
  local owner="${2:-}"
  local mode="${3:-0644}"
  local has_blesh=0
  local home_dir

  [ -e "$bashrc" ] || return 0

  if grep -q 'blesh/ble\.sh\|ble\.sh' "$bashrc" 2>/dev/null; then
    has_blesh=1
  fi

  [ "$has_blesh" -eq 1 ] || return 0

  backup_file "$bashrc"

  sed -i '/# >>> ble\.sh >>>/,/# <<< ble\.sh <<</d' "$bashrc"
  sed -i '/blesh\/ble\.sh/d' "$bashrc"

  cat >> "$bashrc" <<'EOS'

# >>> ble.sh >>>
if [[ $- == *i* && -r "$HOME/.local/share/blesh/ble.sh" ]]; then
  source "$HOME/.local/share/blesh/ble.sh"
fi

# Re-apply Kel color terminal after ble.sh
if [[ $- == *i* && -r /etc/profile.d/99-kel-color-terminal.sh ]]; then
  source /etc/profile.d/99-kel-color-terminal.sh
fi
# <<< ble.sh <<<
EOS

  [ -n "$owner" ] && chown "$owner" "$bashrc" || true
  chmod "$mode" "$bashrc" || true
  log "Исправлена совместимость ble.sh + color terminal: $bashrc"
}

install -d -m 0755 /etc/profile.d
backup_file "$PROFILE_SNIPPET"
cat > "$PROFILE_SNIPPET" <<'EOS'
# Kel color terminal profile.
# Safe for interactive Bash only.

if [ -z "${BASH_VERSION:-}" ]; then
  return 0 2>/dev/null || exit 0
fi

case "$-" in
  *i*) ;;
  *) return 0 2>/dev/null || exit 0 ;;
esac

if [ "${TERM:-}" = "dumb" ]; then
  PS1='[\u@\h:\w]\\$ '
  return 0 2>/dev/null || exit 0
fi

HISTCONTROL=ignoreboth
HISTSIZE=1000
HISTFILESIZE=2000
shopt -s histappend 2>/dev/null || true
shopt -s checkwinsize 2>/dev/null || true

if ! shopt -oq posix 2>/dev/null; then
  if [ -f /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
  elif [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
  fi
fi

if [ -x /usr/lib/command-not-found ] || [ -x /usr/share/command-not-found/command-not-found ]; then
  command_not_found_handle() {
    if [ -x /usr/lib/command-not-found ]; then
      /usr/lib/command-not-found -- "$1"
      return $?
    elif [ -x /usr/share/command-not-found/command-not-found ]; then
      /usr/share/command-not-found/command-not-found -- "$1"
      return $?
    else
      printf '%s: command not found\n' "$1" >&2
      return 127
    fi
  }
fi

alias ls='ls --color=auto -l -a'
alias ll='ls --color=auto -l -a'
alias la='ls --color=auto -A'
alias dir='dir --color=auto'
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'
alias rm='rm -i'
alias srm='shred -uvz'
alias ping='ping -4'

killtty() {
  if [ -z "${1:-}" ]; then
    echo "usage: killtty <N>" >&2
    return 2
  fi
  pkill -9 -t "pts/$1"
}

__kel_color_prompt() {
  local reset='\[\e[0m\]'
  local time_c='\[\e[0;35m\]'
  local root_c='\[\e[0;91m\]'
  local user_c='\[\e[0;92m\]'
  local host_c='\[\e[0;94m\]'
  local path_c='\[\e[0;93m\]'
  local uid_now

  uid_now="$(id -u 2>/dev/null || echo 99999)"

  if [ "$uid_now" -eq 0 ]; then
    PS1="${reset}[${time_c}\t${reset}]:${reset}[${root_c}\u${reset}@${host_c}\H${reset}]:${reset}[${path_c}\w${reset}]: ${root_c}>> ${reset}"
  else
    PS1="${reset}[${time_c}\t${reset}]:${reset}[${user_c}\u${reset}@${host_c}\H${reset}]:${reset}[${path_c}\w${reset}]: ${user_c}>> ${reset}"
  fi
}

__kel_color_prompt
unset -f __kel_color_prompt

export DOTNET_CLI_TELEMETRY_OPTOUT=1
EOS
chmod 0644 "$PROFILE_SNIPPET"
log "Установлен профиль: $PROFILE_SNIPPET"

append_source_block "/etc/bash.bashrc" "" "0644"
append_source_block "/root/.bashrc" "root:root" "0644"
ensure_profile_sources_bashrc "/root/.profile" "root:root"
repair_existing_blesh_block "/root/.bashrc" "root:root" "0644"

if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
  user_home="$(getent passwd "$SUDO_USER" | cut -d: -f6 || true)"
  user_group="$(id -gn "$SUDO_USER" 2>/dev/null || echo "$SUDO_USER")"

  if [ -n "$user_home" ] && [ -d "$user_home" ]; then
    append_source_block "$user_home/.bashrc" "$SUDO_USER:$user_group" "0644"
    ensure_profile_sources_bashrc "$user_home/.profile" "$SUDO_USER:$user_group"
    repair_existing_blesh_block "$user_home/.bashrc" "$SUDO_USER:$user_group" "0644"
  fi
fi

if command -v apt-get >/dev/null 2>&1; then
  if ! dpkg -s bash-completion >/dev/null 2>&1; then
    warn "bash-completion не установлен. Можно поставить: apt update && apt install -y bash-completion"
  fi
fi

cat <<'EOS'

Готово.

Удаление color terminal:
  rm -f /etc/profile.d/99-kel-color-terminal.sh
  sed -i '/# >>> kel-color-terminal >>>/,/# <<< kel-color-terminal <<</d' /etc/bash.bashrc /root/.bashrc 2>/dev/null || true

Для применения:
  exec bash -l

EOS

if [ -t 0 ] && [ -t 1 ]; then
  echo "Перезапускаю текущую bash-сессию..."
  exec bash -l
else
  echo "Открой новую SSH-сессию или выполни: exec bash -l"
fi
