#!/usr/bin/env bash
# Быстрая настройка сервера на Ubuntu: инструменты разработки, Docker, Node, uv, bun, Go.
# Системные библиотеки для запуска браузера (Camoufox и т.п. на базе Firefox) — без pip-пакетов.
# Запуск без chmod +x: sudo bash setup-server.sh [...]
# С chmod +x можно: sudo ./setup-server.sh [...]
# Запуск: sudo bash setup-server.sh [--skip-docker] [--skip-node]
# Требуется root (EUID 0). При вызове через sudo uv/bun ставятся в домашний каталог вызвавшего пользователя.

set -euo pipefail

# Версия Go (linux-amd64/arm64), см. https://go.dev/dl/
: "${GO_VERSION:=1.23.5}"

SKIP_DOCKER=0
SKIP_NODE=0

for arg in "$@"; do
  case "$arg" in
    --skip-docker) SKIP_DOCKER=1 ;;
    --skip-node) SKIP_NODE=1 ;;
    *)
      echo "Неизвестный аргумент: $arg" >&2
      echo "Использование: $0 [--skip-docker] [--skip-node]" >&2
      exit 1
      ;;
  esac
done

if [[ "${EUID:-}" -ne 0 ]]; then
  echo "Запустите от root, например: sudo bash $0" >&2
  exit 1
fi

# Целевой пользователь для uv/bun (при sudo — владелец сессии, иначе root)
if [[ -n "${SUDO_USER:-}" ]] && id "$SUDO_USER" &>/dev/null; then
  TARGET_USER="$SUDO_USER"
  TARGET_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
else
  TARGET_USER=root
  TARGET_HOME=/root
fi

have_cmd() { command -v "$1" &>/dev/null; }

# Проверка установленного deb-пакета
dpkg_installed() {
  local pkg="$1"
  dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'
}

# Выполнить команду от имени целевого пользователя с корректным HOME
run_as_target() {
  if [[ "$TARGET_USER" == root ]]; then
    HOME="$TARGET_HOME" "$@"
  else
    sudo -u "$TARGET_USER" env HOME="$TARGET_HOME" USER="$TARGET_USER" LOGNAME="$TARGET_USER" "$@"
  fi
}

# Поддерживается только Ubuntu (apt)
require_ubuntu() {
  if [[ ! -f /etc/os-release ]]; then
    echo "Не найден /etc/os-release." >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  . /etc/os-release
  if [[ "${ID:-}" != "ubuntu" ]]; then
    echo "Поддерживается только Ubuntu (ожидается ID=ubuntu в /etc/os-release). Сейчас: ID=${ID:-?}" >&2
    exit 1
  fi
  if ! have_cmd apt-get; then
    echo "Не найден apt-get." >&2
    exit 1
  fi
}

# На Ubuntu 24.04+ часть библиотек переименована (t64); libasound2 — только виртуальный пакет.
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
    *)
      echo "Неподдерживаемая архитектура: $(uname -m)" >&2
      exit 1
      ;;
  esac
}

# --- Фаза 1: базовые пакеты + библиотеки для Firefox/Camoufox (системные, без Python) ---
install_native_batch() {
  echo "=== Фаза 1: базовые пакеты и системные библиотеки для браузера (Camoufox и др.) ==="

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq

  # Системные библиотеки для Firefox/Camoufox (имена зависят от версии Ubuntu, см. camoufox_browser_apt_pkgs)
  # unzip нужен официальному установщику bun (иначе «error: unzip is required to install bun»)
  local pkgs=(curl ca-certificates gnupg lsb-release git build-essential unzip)
  local bl
  while IFS= read -r bl; do
    [[ -n "$bl" ]] && pkgs+=("$bl")
  done < <(camoufox_browser_apt_pkgs)

  local missing=()
  for p in "${pkgs[@]}"; do
    if ! dpkg_installed "$p"; then
      missing+=("$p")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Устанавливаю (apt): ${missing[*]}"
    apt-get install -y "${missing[@]}"
  else
    echo "Все перечисленные apt-пакеты уже установлены — пропуск."
  fi
}

# --- Фаза 2a: Docker (официальный скрипт) ---
install_docker() {
  [[ "$SKIP_DOCKER" == 1 ]] && { echo "Пропуск Docker (--skip-docker)."; return 0; }
  if have_cmd docker; then
    echo "Docker уже в PATH — пропуск установки."
    return 0
  fi
  echo "=== Установка Docker (get.docker.com) ==="
  curl -fsSL https://get.docker.com | sh
}

# Доступ к docker.sock без sudo: пользователь должен быть в группе docker (после — новый вход или newgrp docker)
ensure_docker_group() {
  if ! have_cmd docker; then
    return 0
  fi
  if ! getent group docker &>/dev/null; then
    return 0
  fi
  if [[ "$TARGET_USER" == root ]]; then
    return 0
  fi
  if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx docker; then
    echo "Пользователь $TARGET_USER уже в группе docker."
    return 0
  fi
  echo "=== Docker: добавляю пользователя $TARGET_USER в группу docker ==="
  usermod -aG docker "$TARGET_USER"
  echo "Чтобы заработало docker ps без sudo: выйдите из сессии и войдите снова (в WSL: wsl --shutdown с Windows), либо выполните: newgrp docker"
}

# --- Фаза 2b: Node.js LTS + npm ---
install_node() {
  [[ "$SKIP_NODE" == 1 ]] && { echo "Пропуск Node.js (--skip-node)."; return 0; }
  if have_cmd node && have_cmd npm; then
    echo "Node.js и npm уже доступны — пропуск установки Node."
    return 0
  fi

  echo "=== Установка Node.js LTS (NodeSource) ==="
  export DEBIAN_FRONTEND=noninteractive
  curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
  apt-get install -y nodejs
}

install_pm2() {
  [[ "$SKIP_NODE" == 1 ]] && return 0
  if have_cmd pm2; then
    echo "pm2 уже установлен — пропуск."
    return 0
  fi
  if ! have_cmd npm; then
    echo "npm не найден — pm2 не устанавливаю." >&2
    return 0
  fi
  echo "=== Установка pm2 (глобально через npm) ==="
  npm install -g pm2
}

# --- Фаза 3: параллельно uv, bun, Go (без apt внутри) ---
job_install_uv() {
  if [[ -x "${TARGET_HOME}/.local/bin/uv" ]]; then
    echo "[uv] уже установлен (${TARGET_HOME}/.local/bin/uv)."
    return 0
  fi
  echo "[uv] установка через astral.sh…"
  run_as_target bash -c 'set -euo pipefail; curl -LsSf https://astral.sh/uv/install.sh | sh'
}

job_install_bun() {
  if [[ -x "${TARGET_HOME}/.bun/bin/bun" ]]; then
    echo "[bun] уже установлен (${TARGET_HOME}/.bun/bin/bun)."
    return 0
  fi
  echo "[bun] установка через bun.sh…"
  run_as_target bash -c 'set -euo pipefail; curl -fsSL https://bun.sh/install | bash'
}

job_install_go() {
  if PATH="/usr/local/go/bin:/usr/local/bin:${PATH}" command -v go &>/dev/null; then
    echo "[go] уже доступен в PATH — пропуск установки в /usr/local/go."
    return 0
  fi
  local suffix arch tarball url tmpdir
  suffix="$(go_arch_suffix)"
  arch="linux-${suffix}"
  tarball="go${GO_VERSION}.${arch}.tar.gz"
  url="https://go.dev/dl/${tarball}"
  tmpdir="$(mktemp -d)"
  echo "[go] скачивание ${url}…"
  curl -fsSL "$url" -o "${tmpdir}/${tarball}"
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "${tmpdir}/${tarball}"
  rm -rf "${tmpdir}"
  ln -sf /usr/local/go/bin/go /usr/local/bin/go 2>/dev/null || true
  ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt 2>/dev/null || true
  echo "[go] установлен в /usr/local/go (версия ${GO_VERSION})."
}

run_parallel_tooling() {
  echo "=== Фаза 3: параллельная установка uv, bun, Go ==="
  export PATH="${TARGET_HOME}/.local/bin:${TARGET_HOME}/.bun/bin:/usr/local/go/bin:/usr/local/bin:${PATH}"

  local pids=() ec=0

  ( job_install_uv ) &
  pids+=("$!")
  ( job_install_bun ) &
  pids+=("$!")
  ( job_install_go ) &
  pids+=("$!")

  for pid in "${pids[@]}"; do
    wait "$pid" || ec=1
  done

  if [[ "$ec" -ne 0 ]]; then
    echo "Одна из параллельных установок завершилась с ошибкой." >&2
    exit 1
  fi
}

# PATH для uv/bun/go во всех новых интерактивных сессиях (и login), без ручного export
PROFILE_D_PATH=/etc/profile.d/setup-server-dev-path.sh
install_profile_d_path() {
  echo "=== Запись PATH в ${PROFILE_D_PATH} (uv, bun, Go) ==="
  cat >"${PROFILE_D_PATH}" <<'EOF'
# Создано setup-server.sh: uv (~/.local/bin), bun (~/.bun/bin), Go (/usr/local/go/bin)
# Используется $HOME текущего пользователя при входе в систему.
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
}

print_path_hints() {
  echo ""
  echo "=== Готово ==="
  echo "PATH для uv / bun / Go записан в: ${PROFILE_D_PATH}"
  echo "В этом же окне терминала выполните один раз:"
  echo "  source ${PROFILE_D_PATH}"
  echo "После этого: uv --version, bun --version"
  echo ""
  echo "Пакеты camoufox/pydoll в этот скрипт не входят — установите их в своём venv при необходимости."
  echo "Системные библиотеки для Firefox (Camoufox) см.: https://camoufox.com/python/installation/"
}

# --- main ---
require_ubuntu
install_native_batch
install_docker
ensure_docker_group
install_node

run_parallel_tooling

export PATH="${TARGET_HOME}/.local/bin:${TARGET_HOME}/.bun/bin:/usr/local/go/bin:/usr/local/bin:${PATH}"
install_pm2

install_profile_d_path
print_path_hints
