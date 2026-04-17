#!/usr/bin/env bash
# Проверка локальных SSH-ключей, при необходимости создание и регистрация в Gogs через API.
# Запуск: bash setup-gogs-ssh-key.sh <BASE_URL_GOGS> <API_TOKEN>
# Пример BASE_URL: https://gogs.example.com или http://95.216.48.86:3000 (веб-интерфейс, не git@...)
# Требования: curl, python3 (для разбора JSON ответа API).

set -euo pipefail

# --- Цвета и логи (в духе setup-server.sh) ---
setup_colors() {
  if [[ -t 1 ]]; then
    B=$'\033[1m'
    D=$'\033[2m'
    G=$'\033[32m'
    R=$'\033[31m'
    Y=$'\033[33m'
    C=$'\033[36m'
    M=$'\033[35m'
    N=$'\033[0m'
  else
    B='' D='' G='' R='' Y='' C='' M='' N=''
  fi
}
setup_colors

die() { printf '%b%s%b\n' "$R" "$*" "$N" >&2; exit 1; }

section() {
  printf '\n%b── %s ──%b\n' "$C$B" "$*" "$N"
}

row_ok() { printf '  %b[+]%b %s\n' "$G" "$N" "$*"; }
row_need() { printf '  %b[-]%b %s\n' "$R" "$N" "$*"; }
row_skip() { printf '  %b·%b %s\n' "$Y" "$N" "$*"; }
row_note() { printf '  %b%s%b\n' "$D" "$*" "$N"; }
row_info() { printf '  %b[*]%b %s\n' "$C" "$N" "$*"; }

usage() {
  printf '%s\n' "Использование: $0 <GOGS_BASE_URL> <API_TOKEN>" >&2
  printf '%s\n' "  GOGS_BASE_URL — адрес веб-интерфейса, например https://git.company или http://IP:3000" >&2
  printf '%s\n' "  API_TOKEN       — персональный токен Gogs (Settings → Applications)" >&2
  exit 1
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage
[[ $# -ge 2 ]] || usage

GOGS_RAW_URL="$1"
API_TOKEN="$2"

have_cmd() { command -v "$1" &>/dev/null; }

have_cmd curl || die "Нужен curl."
have_cmd python3 || die "Нужен python3 (для разбора JSON API)."

# Нормализация базового URL и корня API
normalize_gogs_base() {
  local u="$1"
  u="${u%/}"
  # Убираем завершающий /api/v1 если пользователь его указал
  if [[ "$u" == */api/v1 ]]; then
    u="${u%/api/v1}"
  fi
  printf '%s' "$u"
}

GOGS_BASE="$(normalize_gogs_base "$GOGS_RAW_URL")"
API_ROOT="${GOGS_BASE}/api/v1"

GOGS_KEYS_JSON="$(mktemp)"
GOGS_POST_JSON="$(mktemp)"
LOCAL_FPS_FILE="$(mktemp)"
cleanup_tmp() {
  rm -f "$GOGS_KEYS_JSON" "$GOGS_POST_JSON" "$LOCAL_FPS_FILE" 2>/dev/null || true
}
trap cleanup_tmp EXIT

# Из строки публичного ключа берём «тип + тело» без комментария (для сравнения с ответом Gogs)
fingerprint_line() {
  # Первые два поля OpenSSH: алгоритм и ключ
  awk 'NF>=2 {print $1" "$2; exit}' <<<"$1"
}

# Список путей к локальным публичным ключам в порядке приоритета
collect_local_pub_paths() {
  [[ -n "${HOME:-}" ]] || return 0
  local ssh_dir="${HOME}/.ssh"
  [[ -d "$ssh_dir" ]] || return 0
  local f
  for f in "$ssh_dir/id_ed25519.pub" "$ssh_dir/id_rsa.pub" "$ssh_dir/id_ecdsa.pub"; do
    [[ -f "$f" ]] && printf '%s\n' "$f"
  done
}

ensure_local_ssh_key() {
  section "Локальные SSH-ключи"
  local pub_paths
  pub_paths="$(collect_local_pub_paths || true)"
  if [[ -n "$pub_paths" ]]; then
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      row_ok "Найден: $p"
    done <<<"$pub_paths"
    return 0
  fi

  row_need "Публичные ключи (id_ed25519/id_rsa/id_ecdsa) не найдены."
  local ssh_dir="${HOME}/.ssh"
  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir" 2>/dev/null || true

  local key_path="${ssh_dir}/id_ed25519"
  row_info "Создаю пару ключей Ed25519: ${key_path}(.pub)"
  if ssh-keygen -t ed25519 -f "$key_path" -N "" -C "gogs-auto-$(hostname)-$(date -Iseconds 2>/dev/null || date)" -q; then
    chmod 600 "$key_path" 2>/dev/null || true
    chmod 644 "${key_path}.pub" 2>/dev/null || true
    row_ok "Создан ключ: ${key_path}.pub"
  else
    die "Не удалось выполнить ssh-keygen."
  fi
}

# Предпочитаемый публичный ключ для отправки в Gogs
pick_primary_pubkey_file() {
  local f
  for f in "${HOME}/.ssh/id_ed25519.pub" "${HOME}/.ssh/id_rsa.pub" "${HOME}/.ssh/id_ecdsa.pub"; do
    if [[ -f "$f" ]]; then
      printf '%s' "$f"
      return 0
    fi
  done
  return 1
}

# Записывает в файл строки «тип тело» для всех найденных локальных .pub
build_local_fingerprints_file() {
  local out="$1"
  : >"$out"
  local pub_paths p c fp
  pub_paths="$(collect_local_pub_paths || true)"
  while IFS= read -r p; do
    [[ -n "$p" && -f "$p" ]] || continue
    c="$(tr -d '\r' <"$p")"
    fp="$(fingerprint_line "$c")"
    [[ -n "$fp" ]] && printf '%s\n' "$fp" >>"$out"
  done <<<"$pub_paths"
}

# GET /user/keys — список ключей текущего пользователя по токену
fetch_remote_keys_json() {
  local url="${API_ROOT}/user/keys"
  local http
  http="$(curl -sS -w '%{http_code}' -o "$GOGS_KEYS_JSON" \
    -H "Authorization: token ${API_TOKEN}" \
    -H "Accept: application/json" \
    "$url" || true)"
  printf '%s' "$http"
}

# POST новый ключ
post_public_key() {
  local title="$1"
  local key_content="$2"
  local payload
  payload="$(python3 -c "import json,sys; print(json.dumps({'title':sys.argv[1],'key':sys.argv[2]}))" "$title" "$key_content")"

  curl -sS -o "$GOGS_POST_JSON" -w '%{http_code}' \
    -X POST "${API_ROOT}/user/keys" \
    -H "Authorization: token ${API_TOKEN}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "$payload"
}

section "Параметры"
row_note "Gogs API: ${API_ROOT}"
row_note "Токен: ${API_TOKEN:0:6}… (полный не показываем)"

ensure_local_ssh_key

PRIMARY_PUB="$(pick_primary_pubkey_file)" || die "Не удалось выбрать файл публичного ключа."
PUB_CONTENT="$(tr -d '\r' <"$PRIMARY_PUB")"
[[ -n "$PUB_CONTENT" ]] || die "Файл публичного ключа пуст: $PRIMARY_PUB"

build_local_fingerprints_file "$LOCAL_FPS_FILE"
[[ -s "$LOCAL_FPS_FILE" ]] || die "Некорректное содержимое локальных .pub"

section "Запрос ключей из Gogs"
HTTP_CODE="$(fetch_remote_keys_json)"
if [[ "$HTTP_CODE" != "200" ]]; then
  row_need "API вернул код ${HTTP_CODE}"
  if [[ -f "$GOGS_KEYS_JSON" ]]; then
    row_note "$(head -c 400 "$GOGS_KEYS_JSON")"
  fi
  die "Проверьте URL и токен (нужны права на ключи пользователя)."
fi

MATCHES="$(
  python3 - "$GOGS_KEYS_JSON" "$LOCAL_FPS_FILE" <<'PY'
"""Сравнение локальных отпечатков (тип+тело) с ключами из ответа Gogs."""
import json
import sys

keys_path, fps_path = sys.argv[1], sys.argv[2]
with open(keys_path, "r", encoding="utf-8") as f:
    data = json.load(f)
if not isinstance(data, list):
    print("0")
    raise SystemExit(0)
remote_set = set()
for item in data:
    k = (item.get("key") or "").strip()
    parts = k.split()
    if len(parts) >= 2:
        remote_set.add((parts[0], parts[1]))
with open(fps_path, "r", encoding="utf-8") as f:
    local_lines = [ln.strip() for ln in f if ln.strip()]
for ln in local_lines:
    p = ln.split()
    if len(p) >= 2 and (p[0], p[1]) in remote_set:
        print("1")
        raise SystemExit(0)
print("0")
PY
)"

if [[ "$MATCHES" == "1" ]]; then
  section "Результат"
  row_ok "Один из локальных ключей уже зарегистрирован в Gogs (совпадают тип и тело)."
  row_note "Для push/pull будет использован существующий ключ из ~/.ssh"
  row_skip "Добавление не требуется."
  exit 0
fi

section "Добавление ключа в Gogs"
TITLE="auto-$(hostname)-$(date +%Y%m%d%H%M%S 2>/dev/null || echo ts)"
row_info "Заголовок ключа в Gogs: $TITLE"

POST_CODE="$(post_public_key "$TITLE" "$PUB_CONTENT")"
POST_BODY="$(cat "$GOGS_POST_JSON" 2>/dev/null || true)"

if [[ "$POST_CODE" == "201" ]]; then
  row_ok "Ключ успешно добавлен (HTTP 201)."
elif [[ "$POST_CODE" == "422" ]]; then
  # Часто дубликат или ошибка валидации
  row_need "API отклонил ключ (HTTP 422). Ответ:"
  row_note "$POST_BODY"
  exit 1
else
  row_need "Неожиданный код ответа: $POST_CODE"
  row_note "$POST_BODY"
  exit 1
fi

section "Готово"
row_ok "Можно клонировать по SSH согласно настройкам вашего Gogs (git@хост:...)."
row_note "Проверка: ssh -T git@<хост_из_URL_SSH_клона>"
