#!/usr/bin/env bash
# awg-up.sh — одноразовый VPS -> AmneziaWG 2.0 сервер + готовый конфиг для роутера.
# Обёртка над https://github.com/bivlked/amneziawg-installer (Ubuntu 24.04).
#
# Запускать от root на ЧИСТОМ VPS. Скрипт сам понимает, на каком он шаге:
#   - установка ещё не завершена -> запускает установщик (он перезагрузит сервер 2 раза)
#   - установка завершена        -> создаёт клиента и печатает конфиг
# То есть после каждой перезагрузки просто запускаешь ту же команду снова.
#
# Переменные (необязательно):
#   CLIENT_NAME=beryl   имя клиента (по умолчанию beryl)
#   AWG_PORT=443        UDP-порт сервера (по умолчанию выбирает установщик)

set -euo pipefail

CLIENT_NAME="${CLIENT_NAME:-beryl}"
AWG_PORT="${AWG_PORT:-}"
INSTALLER_URL="https://github.com/bivlked/amneziawg-installer/releases/latest/download/install_amneziawg.sh"
INSTALLER_PATH="/root/install_amneziawg.sh"
AWG_DIR="/root/awg"
MANAGE="$AWG_DIR/manage_amneziawg.sh"
CLIENT_CONF="$AWG_DIR/$CLIENT_NAME.conf"

if [ "$(id -u)" -ne 0 ]; then
  echo "Запусти от root (sudo -i, потом снова эту команду)." >&2
  exit 1
fi

installed() {
  [ -x "$MANAGE" ] && systemctl is-active --quiet awg-quick@awg0 2>/dev/null
}

public_ip() {
  curl -4 -fsS --max-time 8 https://ifconfig.me 2>/dev/null \
    || curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null \
    || echo "<IP_СЕРВЕРА>"
}

if ! installed; then
  echo ">>> Шаг: установка AmneziaWG 2.0"
  if [ ! -f "$INSTALLER_PATH" ]; then
    echo ">>> Скачиваю установщик..."
    if command -v wget >/dev/null 2>&1; then
      wget -q -O "$INSTALLER_PATH" "$INSTALLER_URL"
    else
      curl -fsSL -o "$INSTALLER_PATH" "$INSTALLER_URL"
    fi
    chmod +x "$INSTALLER_PATH"
  fi

  args=(--yes --route-all)
  if [ -n "$AWG_PORT" ]; then
    args+=("--port=$AWG_PORT")
  fi

  echo ">>> Запускаю: bash $INSTALLER_PATH ${args[*]}"
  echo ">>> Если сервер уйдёт в перезагрузку — подожди ~1 минуту, зайди по SSH"
  echo ">>> и запусти ТУ ЖЕ команду снова. Всего будет 2 перезагрузки."
  bash "$INSTALLER_PATH" "${args[@]}"

  # Если установщик дошёл до конца без перезагрузки — продолжаем сразу.
  if ! installed; then
    echo
    echo ">>> Установка ещё не завершена. Запусти эту же команду ещё раз"
    echo ">>> (после перезагрузки, если она была)."
    exit 0
  fi
fi

echo ">>> Установка завершена. Готовлю клиента '$CLIENT_NAME'..."
if [ ! -f "$CLIENT_CONF" ]; then
  bash "$MANAGE" add "$CLIENT_NAME"
fi

if [ ! -f "$CLIENT_CONF" ]; then
  echo "Не нашёл $CLIENT_CONF. Список клиентов: bash $MANAGE list" >&2
  exit 1
fi

IP="$(public_ip)"
echo
echo "=================== ГОТОВО ==================="
echo "Сервер:  $IP"
echo "Клиент:  $CLIENT_NAME"
echo "Файл:    $CLIENT_CONF"
echo
echo "--- Скачать на компьютер (выполнить на своей машине) ---"
echo "scp root@$IP:$CLIENT_CONF ."
echo
echo "--- Или скопировать текст конфига отсюда ---"
echo "=============== НАЧАЛО КОНФИГА ==============="
cat "$CLIENT_CONF"
echo "================ КОНЕЦ КОНФИГА ================"
echo
echo "Этот конфиг -> в роутер (VPN -> WireGuard Client -> загрузить файл)."
echo "Когда VPS больше не нужен — просто удали его в панели хостинга."
