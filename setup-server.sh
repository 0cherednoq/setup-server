#!/usr/bin/env bash
# Быстрая настройка сервера на Ubuntu: Docker, Node, uv, bun, Go, pm2.
# Системные библиотеки для Firefox/Camoufox ставятся в конце (отдельный шаг apt).
# Запуск: sudo bash setup-server.sh [--skip-docker] [--skip-node] [--skip-apt-update]
# Из curl (флаги только после «bash -s --»): curl -fsSL URL | sudo bash -s -- --skip-apt-update
# Без chmod: sudo bash setup-server.sh

set -euo pipefail

: "${GO_VERSION:=1.23.5}"

SKIP_DOCKER=0
SKIP_NODE=0
# Не вызывать apt-get update (быстрее, если индексы уже свежие; при ошибках apt — уберите флаг)
SKIP_APT_UPDATE=0
# Уже выполняли apt-get update в этом запуске скрипта
APT_LISTS_REFRESHED=0

for arg in "$@"; do
  case "$arg" in
    --skip-docker) SKIP_DOCKER=1 ;;
    --skip-node) SKIP_NODE=1 ;;
    --skip-apt-update) SKIP_APT_UPDATE=1 ;;
    *)
      printf '%s\n' "Неизвестный аргумент: $arg" >&2
      printf '%s\n' "Использование: $0 [--skip-docker] [--skip-node] [--skip-apt-update]" >&2
      exit 1
      ;;
  esac
done

if [[ "${EUID:-}" -ne 0 ]]; then
  printf '%s\n' "Запустите от root: sudo bash $0" >&2
  exit 1
fi

if [[ -n "${SUDO_USER:-}" ]] && id "$SUDO_USER" &>/dev/null; then
  TARGET_USER="$SUDO_USER"
  TARGET_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
else
  TARGET_USER=root
  TARGET_HOME=/root
fi

# Цвета только при интерактивном терминале
setup_colors() {
  if [[ -t 1 ]]; then
    B=$'\033[1m'
    D=$'\033[2m'
    G=$'\033[32m'
    R=$'\033[31m'
    Y=$'\033[33m'
    C=$'\033[36m'
    N=$'\033[0m'
  else
    B='' D='' G='' R='' Y='' C='' N=''
  fi
}
setup_colors

have_cmd() { command -v "$1" &>/dev/null; }

dpkg_installed() {
  local pkg="$1"
  dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'
}

run_as_target() {
  if [[ "$TARGET_USER" == root ]]; then
    HOME="$TARGET_HOME" "$@"
  else
    sudo -u "$TARGET_USER" env HOME="$TARGET_HOME" USER="$TARGET_USER" LOGNAME="$TARGET_USER" "$@"
  fi
}

die() { printf '%b%s%b\n' "$R" "$*" "$N" >&2; exit 1; }

section() {
  printf '\n%b── %s ──%b\n' "$C$B" "$*" "$N"
}

# [+] есть (зелёный), [-] нет (красный)
row_ok() { printf '  %b[+]%b %s\n' "$G" "$N" "$*"; }
row_need() { printf '  %b[-]%b %s\n' "$R" "$N" "$*"; }
row_skip() { printf '  %b·%b %s\n' "$Y" "$N" "$*"; }
row_note() { printf '  %b%s%b\n' "$D" "$*" "$N"; }

require_ubuntu() {
  if [[ ! -f /etc/os-release ]]; then
    die "Не найден /etc/os-release."
  fi
  # shellcheck source=/dev/null
  . /etc/os-release
  if [[ "${ID:-}" != "ubuntu" ]]; then
    die "Нужен Ubuntu (ID=ubuntu). Сейчас: ID=${ID:-?}"
  fi
  have_cmd apt-get || die "Не найден apt-get."
}

camoufox_browser_apt_pkgs() {
  local maj="${VERSION_ID%%.*}"
  if [[ "$maj" =~ ^[0-9]+$ ]] && [[ $((10#$maj)) -ge 24 ]]; then
    printf '%s\n' libgtk-3-0t64 libx11-xcb1 libasound2t64
  else
    printf '%s\n' libgtk-3-0 libx11-xcb1 libasound2
  fi
}

go_arch_suffix() {
  case "$(uname -m)" in
    x86_64) echo amd64 ;;
    aarch64 | arm64) echo arm64 ;;
    *) die "Неподдерживаемая архитектура: $(uname -m)" ;;
  esac
}

# Обновить индексы apt не чаще одного раза за запуск; не вызывается, если ставить нечего или задан --skip-apt-update
ensure_apt_lists() {
  export DEBIAN_FRONTEND=noninteractive
  [[ "$SKIP_APT_UPDATE" == 1 ]] && return 0
  [[ "$APT_LISTS_REFRESHED" == 1 ]] && return 0
  section "APT: обновление индексов"
  apt-get update -qq
  APT_LISTS_REFRESHED=1
  row_note "готово"
}

# Базовые пакеты (без библиотек Camoufox — они в конце)
install_base_apt_packages() {
  section "Базовые пакеты"
  local pkgs=(
    curl ca-certificates gnupg lsb-release git
    build-essential unzip
  )
  local missing=() p
  for p in "${pkgs[@]}"; do
    if dpkg_installed "$p"; then
      row_ok "$p"
    else
      row_need "$p"
      missing+=("$p")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    ensure_apt_lists
    printf '\n%b  → apt install:%b %s\n' "$B" "$N" "${missing[*]}"
    apt-get install -y "${missing[@]}"
  fi
}

# Последний шаг apt: только библиотеки под Firefox/Camoufox
install_camoufox_system_libs() {
  section "Системные библиотеки для Camoufox (Firefox)"
  local pkgs=() bl missing=() p
  while IFS= read -r bl; do
    [[ -n "$bl" ]] && pkgs+=("$bl")
  done < <(camoufox_browser_apt_pkgs)

  for p in "${pkgs[@]}"; do
    if dpkg_installed "$p"; then
      row_ok "$p"
    else
      row_need "$p"
      missing+=("$p")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    ensure_apt_lists
    printf '\n%b  → apt install:%b %s\n' "$B" "$N" "${missing[*]}"
    apt-get install -y "${missing[@]}"
  fi
}

install_docker() {
  section "Docker"
  if [[ "$SKIP_DOCKER" == 1 ]]; then
    row_skip "пропуск (--skip-docker)"
    return 0
  fi
  if have_cmd docker; then
    row_ok "docker (уже в PATH)"
    return 0
  fi
  row_need "docker — установка (get.docker.com)"
  curl -fsSL https://get.docker.com | sh
  row_ok "docker установлен"
}

ensure_docker_group() {
  section "Права Docker (группа docker)"
  if ! have_cmd docker || ! getent group docker &>/dev/null; then
    row_note "docker или группа docker недоступны — шаг пропущен"
    return 0
  fi
  if [[ "$TARGET_USER" == root ]]; then
    row_note "целевой пользователь root — добавление в группу не требуется"
    return 0
  fi
  if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx docker; then
    row_ok "пользователь $TARGET_USER уже в группе docker"
    return 0
  fi
  row_need "добавить $TARGET_USER в группу docker"
  usermod -aG docker "$TARGET_USER"
  row_ok "группа обновлена (нужен новый вход в сессию или: newgrp docker)"
}

install_node() {
  section "Node.js LTS + npm"
  if [[ "$SKIP_NODE" == 1 ]]; then
    row_skip "пропуск (--skip-node)"
    return 0
  fi
  if have_cmd node && have_cmd npm; then
    row_ok "node + npm"
    return 0
  fi
  row_need "node + npm — установка (NodeSource)"
  export DEBIAN_FRONTEND=noninteractive
  ensure_apt_lists
  curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
  apt-get install -y nodejs
  row_ok "node + npm установлены"
}

install_pm2() {
  section "pm2"
  if [[ "$SKIP_NODE" == 1 ]]; then
    row_skip "пропуск (вместе с Node)"
    return 0
  fi
  if have_cmd pm2; then
    row_ok "pm2"
    return 0
  fi
  if ! have_cmd npm; then
    row_need "npm нет — pm2 не ставим"
    return 0
  fi
  row_need "pm2 — npm install -g"
  npm install -g pm2 --silent --no-fund --no-audit 2>/dev/null || npm install -g pm2 --silent
  row_ok "pm2"
}

# Тихая установка в фоне; статус — после wait
job_install_uv() {
  [[ -x "${TARGET_HOME}/.local/bin/uv" ]] && return 0
  run_as_target bash -c 'set -euo pipefail; curl -LsSf https://astral.sh/uv/install.sh | sh' &>/dev/null
}

job_install_bun() {
  [[ -x "${TARGET_HOME}/.bun/bin/bun" ]] && return 0
  run_as_target bash -c 'set -euo pipefail; curl -fsSL https://bun.sh/install | bash' &>/dev/null
}

job_install_go() {
  PATH="/usr/local/go/bin:/usr/local/bin:${PATH}" command -v go &>/dev/null && return 0
  local suffix arch tarball url tmpdir
  suffix="$(go_arch_suffix)"
  arch="linux-${suffix}"
  tarball="go${GO_VERSION}.${arch}.tar.gz"
  url="https://go.dev/dl/${tarball}"
  tmpdir="$(mktemp -d)"
  curl -fsSL "$url" -o "${tmpdir}/${tarball}"
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "${tmpdir}/${tarball}"
  rm -rf "${tmpdir}"
  ln -sf /usr/local/go/bin/go /usr/local/bin/go 2>/dev/null || true
  ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt 2>/dev/null || true
}

run_parallel_tooling() {
  section "uv · bun · Go (параллельно)"
  local had_uv had_bun had_go
  had_uv=0; [[ -x "${TARGET_HOME}/.local/bin/uv" ]] && had_uv=1
  had_bun=0; [[ -x "${TARGET_HOME}/.bun/bin/bun" ]] && had_bun=1
  had_go=0; PATH="/usr/local/go/bin:/usr/local/bin:${PATH}" command -v go &>/dev/null && had_go=1

  if [[ "$had_uv" == 1 ]]; then row_ok "uv"; else row_need "uv"; fi
  if [[ "$had_bun" == 1 ]]; then row_ok "bun"; else row_need "bun"; fi
  if [[ "$had_go" == 1 ]]; then row_ok "go"; else row_need "go"; fi

  export PATH="${TARGET_HOME}/.local/bin:${TARGET_HOME}/.bun/bin:/usr/local/go/bin:/usr/local/bin:${PATH}"
  local pids=() ec=0
  ( job_install_uv ) &
  pids+=("$!")
  ( job_install_bun ) &
  pids+=("$!")
  ( job_install_go ) &
  pids+=("$!")

  if [[ "$had_uv$had_bun$had_go" != "111" ]]; then
    printf '\n%b  … загрузка и установка%b\n' "$D" "$N"
  fi
  for pid in "${pids[@]}"; do
    wait "$pid" || ec=1
  done
  [[ "$ec" -eq 0 ]] || die "Ошибка при установке uv / bun / Go"

  if [[ -x "${TARGET_HOME}/.local/bin/uv" ]] && [[ -x "${TARGET_HOME}/.bun/bin/bun" ]] &&
    PATH="/usr/local/go/bin:/usr/local/bin:${PATH}" command -v go &>/dev/null; then
    row_ok "uv · bun · Go — готово"
  else
    row_need "после установки инструменты не найдены"
    die "uv / bun / Go"
  fi
}

PROFILE_D_PATH=/etc/profile.d/setup-server-dev-path.sh

install_profile_d_path() {
  section "PATH (профиль)"
  cat >"${PROFILE_D_PATH}" <<'EOF'
# setup-server.sh: uv, bun, Go в PATH для каждого пользователя
__setup_server_prepend_path() {
  local d="$1"
  [ -d "$d" ] || return 0
  case ":${PATH:-}:" in
    *:"$d":*) ;;
    *) PATH="$d:$PATH" ;;
  esac
}
__setup_server_prepend_path "$HOME/.local/bin"
__setup_server_prepend_path "$HOME/.bun/bin"
__setup_server_prepend_path "/usr/local/go/bin"
export PATH
unset -f __setup_server_prepend_path 2>/dev/null || true
EOF
  chmod 644 "${PROFILE_D_PATH}"
  row_ok "записано: ${PROFILE_D_PATH}"
}

print_summary() {
  section "Готово"
  row_note "в этом терминале один раз: source ${PROFILE_D_PATH}"
  row_note "затем: uv --version | bun --version | go version"
  printf '\n'
}

# --- точка входа ---
require_ubuntu
printf '\n%b Ubuntu server setup%b  %s\n' "$C$B" "$N" "${PRETTY_NAME:-Ubuntu}"
install_base_apt_packages

install_docker
ensure_docker_group
install_node

run_parallel_tooling

export PATH="${TARGET_HOME}/.local/bin:${TARGET_HOME}/.bun/bin:/usr/local/go/bin:/usr/local/bin:${PATH}"
install_pm2
install_profile_d_path

install_camoufox_system_libs
print_summary
