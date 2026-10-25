#!/usr/bin/env bash
# awg2-up.sh — одноразовый VPS -> AmneziaWG 2.0 сервер + конфиг для роутера (GL.iNet Beryl 7).
#
# Зачем отдельный скрипт: роутер знает только AWG 2.0, а приложение Amnezia и
# установщик bivlked теперь выдают 3.x (HeaderProtectionKey), с которым роутер
# не соединяется. Здесь используется установщик wiresock/amneziawg-install:
# на чистой установке он остаётся на протоколе 2.0, а 3.x включается только
# отдельным флагом, которого мы не передаём.
#
# Важно про S4: установщик ставит S4 != 0 (отступ в пакетах с данными), а
# прошивка GL.iNet 4.9 параметр S4 не применяет (в её `awg show` строки s4 нет).
# Результат: рукопожатие проходит, а пакеты с данными сервер отбрасывает —
# "подключился, а интернета нет". Поэтому скрипт принудительно ставит S4 = 0
# на сервере и в клиентских конфигах (приложение Amnezia с S4 = 0 тоже работает).
#
# Запускать от root на ЧИСТОМ VPS (Ubuntu 24.04 или Debian 12/13).
# Если после установки сервер надо перезагрузить — скрипт скажет, тогда
# просто запусти его ещё раз после перезагрузки (он сам продолжит).
#
# Необязательные переменные:
#   AWG_PORT=443       UDP-порт сервера (по умолчанию установщик берёт случайный)
#   AWG_SKIP_HASH=1    не проверять хеш установщика (если автор его обновил)
#   AWG_KEEP_S4=1      не трогать S4 (нужно только если клиент умеет S4 и роутера нет)

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
AWG_KEEP_S4="${AWG_KEEP_S4:-0}"

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

# Ставит S4 = 0 на сервере и во всех клиентских конфигах; если что-то
# поменялось — перезапускает сервис. Повторный запуск безопасен.
fix_s4() {
  local changed=0 f
  for f in "$AWG_DIR/$NIC.conf" "$HOME_DIR/$NIC"-client-*.conf; do
    [ -f "$f" ] || continue
    if grep -Eq '^S4[[:space:]]*=[[:space:]]*[1-9]' "$f"; then
      sed -i -E 's/^S4[[:space:]]*=.*/S4 = 0/' "$f"
      changed=1
    fi
  done
  if [ "$changed" = "1" ]; then
    echo ">>> Поставил S4 = 0 (роутер GL.iNet параметр S4 не поддерживает), перезапускаю сервис..."
    systemctl restart "awg-quick@$NIC"
    sleep 2
  fi
}

# ---------- Режим диагностики: bash awg2-up.sh diag ----------
# Собирает всё, что нужно, чтобы понять, почему "рукопожатие есть, интернета нет".
diag() {
  if [ ! -e "$AWG_DIR/params" ]; then
    echo "Сервер ещё не установлен." >&2
    exit 1
  fi
  NIC="$(get_param SERVER_AWG_NIC)"
  NIC="${NIC:-awg0}"
  local conf
  conf="$(find_client_conf)"

  echo "##### ip_forward";        sysctl net.ipv4.ip_forward 2>&1 || true
  echo "##### docker";            if command -v docker >/dev/null 2>&1; then echo "docker: установлен"; else echo "docker: нет"; fi
  echo "##### iptables FORWARD";  iptables -S FORWARD 2>&1 || true
  echo "##### DOCKER-USER";       iptables -S DOCKER-USER 2>&1 || true
  echo "##### nft таблица туннеля"; nft list table ip "awg-$NIC" 2>&1 || true
  echo "##### ping с сервера";    ping -c 2 -W 2 1.1.1.1 2>&1 | tail -n 3 || true
  echo "##### awg show (без ключей)"
  awg show 2>&1 | grep -vE "private key|preshared key" || true
  echo "##### клиентский конфиг (без ключей)"
  if [ -n "$conf" ]; then
    grep -E "^(Address|DNS|MTU|AllowedIPs|Endpoint|Jc|Jmin|Jmax|S[1-4]|H[1-4]) " "$conf" || true
  fi
  if command -v tcpdump >/dev/null 2>&1; then
    echo "##### tcpdump на $NIC, 25 секунд: СЕЙЧАС включи VPN на клиенте и открой сайт"
    timeout 25 tcpdump -ni "$NIC" -c 60 2>&1 || true
  else
    echo "##### tcpdump не установлен (apt install -y tcpdump), пропускаю"
  fi
  echo "##### конец диагностики, пришли весь вывод"
}

if [ "${1:-}" = "diag" ]; then
  diag
  exit 0
fi

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

# ---------- Шаг 2б: пересылка не должна резаться Docker/iptables ----------
# На части VPS стоит Docker: он ставит iptables FORWARD в DROP, и правила
# установщика (отдельная таблица nft) этого не отменяют — рукопожатие есть,
# а интернета нет. Разрешаем пересылку для интерфейса туннеля.
if command -v iptables >/dev/null 2>&1 \
   && iptables -S FORWARD 2>/dev/null | grep -q '^-P FORWARD DROP'; then
  if iptables -S DOCKER-USER >/dev/null 2>&1; then
    FWD_CHAIN="DOCKER-USER"
  else
    FWD_CHAIN="FORWARD"
  fi
  echo ">>> iptables FORWARD = DROP, добавляю разрешение для $NIC в $FWD_CHAIN"
  iptables -C "$FWD_CHAIN" -i "$NIC" -j ACCEPT 2>/dev/null \
    || iptables -I "$FWD_CHAIN" 1 -i "$NIC" -j ACCEPT
  iptables -C "$FWD_CHAIN" -o "$NIC" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
    || iptables -I "$FWD_CHAIN" 1 -o "$NIC" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  echo "    (правила не переживают перезагрузку сервера — после reboot запусти скрипт снова)"
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

if [ "$AWG_KEEP_S4" != "1" ]; then
  fix_s4
fi

if grep -q "HeaderProtectionKey" "$CONF"; then
  echo "!!! В конфиге есть HeaderProtectionKey — это 3.x, роутер с ним не соединится." >&2
  echo "    Пришли мне вывод: bash $INSTALLER_PATH --protocol-status" >&2
  exit 1
fi

echo
echo "=================== ГОТОВО ==================="
echo "Сервер:   ${PUB_IP:-?}:${PORT:-?}/udp"
echo "Протокол: AmneziaWG $PROTO.0 (S4 = 0, как нужно роутеру GL.iNet)"
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
echo "Подключился, а интернета нет — запусти диагностику: bash $0 diag"
echo "Когда VPS больше не нужен — удали его в панели хостинга."
