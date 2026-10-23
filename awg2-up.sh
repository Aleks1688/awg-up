#!/usr/bin/env bash
# awg2-up.sh — одноразовый VPS -> AmneziaWG 2.0 сервер + конфиг для роутера (GL.iNet Beryl 7).
#
# Зачем отдельный скрипт: роутер знает только AWG 2.0, а приложение Amnezia и
# установщик bivlked теперь выдают 3.x (HeaderProtectionKey), с которым роутер
# не соединяется. Здесь используется установщик wiresock/amneziawg-install:
# на чистой установке он остаётся на протоколе 2.0, а 3.x включается только
# отдельным флагом, которого мы не передаём.
#
# Запускать от root на ЧИСТОМ VPS (Ubuntu 24.04 или Debian 12/13).
# Если после установки сервер надо перезагрузить — скрипт скажет, тогда
# просто запусти его ещё раз после перезагрузки (он сам продолжит).
#
# Необязательные переменные:
#   AWG_PORT=443       UDP-порт сервера (по умолчанию установщик берёт случайный)
#   AWG_SKIP_HASH=1    не проверять хеш установщика (если автор его обновил)

set -euo pipefail

INSTALLER_URL="${INSTALLER_URL:-https://raw.githubusercontent.com/wiresock/amneziawg-install/main/amneziawg-install.sh}"
# Хеш той версии установщика, код которой я читал. Если автор обновил файл,
# скрипт остановится и покажет новый хеш.
INSTALLER_SHA256="ddf230723ca0c4f3f0d137a27428471db74efd9222130359bdaeb932b73ca431"
INSTALLER_PATH="${INSTALLER_PATH:-/root/amneziawg-install.sh}"
AWG_DIR="${AWG_DIR:-/etc/amnezia/amneziawg}"
HOME_DIR="${AWG_HOME:-/root}"
AWG_PORT="${AWG_PORT:-}"
AWG_SKIP_HASH="${AWG_SKIP_HASH:-0}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Запусти от root (sudo -i, потом снова эту команду)." >&2
  exit 1
fi

get_param() {
  grep -E "^$1=" "$AWG_DIR/params" 2>/dev/null | head -n 1 | cut -d= -f2- | tr -d "'\"" || true
}

find_client_conf() {
  # shellcheck disable=SC2012
  ls -t "$HOME_DIR/$NIC"-client-*.conf 2>/dev/null | head -n 1 || true
}

download_installer() {
  if [ ! -f "$INSTALLER_PATH" ]; then
    echo ">>> Скачиваю установщик..."
    curl -fsSL -o "$INSTALLER_PATH" "$INSTALLER_URL"
  fi
  local got
  got="$(sha256sum "$INSTALLER_PATH" | cut -d' ' -f1)"
  if [ "$got" != "$INSTALLER_SHA256" ] && [ "$AWG_SKIP_HASH" != "1" ]; then
    echo "!!! Хеш установщика не совпал с проверенным." >&2
    echo "    ожидался: $INSTALLER_SHA256" >&2
    echo "    получен:  $got" >&2
    echo "    Автор мог обновить файл. Если доверяешь — запусти так:" >&2
    echo "    AWG_SKIP_HASH=1 bash $0" >&2
    rm -f "$INSTALLER_PATH"
    exit 1
  fi
  chmod +x "$INSTALLER_PATH"
}

# ---------- Шаг 1: установка сервера ----------
if [ ! -e "$AWG_DIR/params" ]; then
  echo ">>> Шаг 1: установка AmneziaWG (протокол 2.0)"
  download_installer

  envs=(AUTO_INSTALL=y ENABLE_IPV6=n CREATE_INITIAL_CLIENT=y
        DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a)
  if [ -n "$AWG_PORT" ]; then
    envs+=("SERVER_PORT=$AWG_PORT")
  fi

  env "${envs[@]}" bash "$INSTALLER_PATH"

  if [ ! -e "$AWG_DIR/params" ]; then
    echo "!!! Установка не завершилась (нет $AWG_DIR/params). Смотри вывод выше." >&2
    exit 1
  fi
else
  echo ">>> Сервер уже установлен, пропускаю установку."
  download_installer
fi

NIC="$(get_param SERVER_AWG_NIC)"
NIC="${NIC:-awg0}"
PUB_IP="$(get_param SERVER_PUB_IP)"
PORT="$(get_param SERVER_PORT)"

# ---------- Шаг 2: сервис работает? ----------
if ! systemctl is-active --quiet "awg-quick@$NIC"; then
  echo
  echo "!!! Сервис awg-quick@$NIC не запущен. Обычно помогает перезагрузка:"
  echo "    reboot"
  echo "    (после перезагрузки зайди по SSH и запусти ТУ ЖЕ команду ещё раз)"
  exit 2
fi

# ---------- Шаг 3: протокол должен быть 2 ----------
PROTO="$(bash "$INSTALLER_PATH" --protocol-status 2>/dev/null | tail -n 1 || true)"
if [ "$PROTO" != "2" ]; then
  echo ">>> Протокол сервера: '${PROTO:-неизвестно}', переключаю на 2.0..."
  bash "$INSTALLER_PATH" --disable-awg3
  PROTO="2"
fi

# ---------- Шаг 4: клиент для роутера ----------
CONF="$(find_client_conf)"
if [ -z "$CONF" ]; then
  echo ">>> Создаю клиента 'client'..."
  bash "$INSTALLER_PATH" --add-client client
  CONF="$(find_client_conf)"
fi

if [ -z "$CONF" ] || [ ! -f "$CONF" ]; then
  echo "!!! Не нашёл клиентский конфиг в $HOME_DIR. Список: bash $INSTALLER_PATH --list-clients" >&2
  exit 1
fi

if grep -q "HeaderProtectionKey" "$CONF"; then
  echo "!!! В конфиге есть HeaderProtectionKey — это 3.x, роутер с ним не соединится." >&2
  echo "    Пришли мне вывод: bash $INSTALLER_PATH --protocol-status" >&2
  exit 1
fi

echo
echo "=================== ГОТОВО ==================="
echo "Сервер:   ${PUB_IP:-?}:${PORT:-?}/udp"
echo "Протокол: AmneziaWG $PROTO.0"
echo "Файл:     $CONF"
echo
echo "--- Скачать на свой компьютер (выполнить на СВОЁМ компьютере) ---"
echo "scp root@${PUB_IP:-IP_СЕРВЕРА}:$CONF ."
echo
echo "=============== НАЧАЛО КОНФИГА ==============="
cat "$CONF"
echo "================ КОНЕЦ КОНФИГА ================"
echo
echo "Дальше: роутер -> VPN -> WireGuard Client -> загрузить этот конфиг -> включить."
echo "Проверка на сервере (появится 'latest handshake' у peer): awg show"
echo "Когда VPS больше не нужен — удали его в панели хостинга."
