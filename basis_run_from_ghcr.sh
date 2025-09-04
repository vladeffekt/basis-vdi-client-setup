#!/bin/bash

# === Настройки ===
CONTAINER_NAME="basis-vdi"
IMAGE_NAME="ghcr.io/vladeffekt/basis-vdi-client:latest"
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
LOG_FILE="$SCRIPT_DIR/basis-vdi-client.log"

# === Путь к конфигу ===
CONFIG_DIR="$HOME/Basis/basis-config"
APP_CONFIG="$CONFIG_DIR/app-config"

# === Функция для вывода в терминал и в лог ===
log_status() {
    echo "[$(date '+%H:%M:%S')] $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# === Очистка старого лога ===
echo "========================================" > "$LOG_FILE"
log_status "Запуск скрипта"

# === Удаляем старый контейнер ===
if docker ps -a -q -f name=^${CONTAINER_NAME}$ | grep -q .; then
    log_status "Остановка старого контейнера"
    docker stop "$CONTAINER_NAME" > /dev/null 2>&1 || true
    docker rm "$CONTAINER_NAME" > /dev/null 2>&1
fi

# === Разрешить доступ к X-серверу ===
log_status "Разрешение доступа к X-серверу"
xhost +local:docker > /dev/null 2>&1

# === Получаем DNS-серверы из /etc/resolv.conf ===
log_status "Поиск DNS-серверов в /etc/resolv.conf"
DNS_SERVERS=()
while IFS= read -r line; do
    if [[ "$line" =~ ^nameserver[[:space:]]+([0-9.]+) ]]; then
        dns="${BASH_REMATCH[1]}"
        if [[ "$dns" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            if [[ "$dns" != "127.0.0.53" && "$dns" != "127.0.0.1" ]]; then
                DNS_SERVERS+=("$dns")
                log_status "Найден DNS: $dns"
            fi
        fi
    fi
done < /etc/resolv.conf

if [ ${#DNS_SERVERS[@]} -eq 0 ]; then
    log_status "Ошибка: не найдено ни одного DNS-сервера в /etc/resolv.conf"
    echo "Ошибка: не найдены DNS-серверы. Убедитесь, что tunsnx подключён."
    exit 1
fi

# === Проверка и загрузка образа ===
log_status "Проверка наличия образа: $IMAGE_NAME"
if docker images -q "$IMAGE_NAME" > /dev/null 2>&1; then
    log_status "Образ найден локально"
else
    log_status "Образ не найден. Начинаю загрузку..."
    echo  # Чтобы прогресс docker pull был виден
    if docker pull "$IMAGE_NAME"; then
        log_status "Образ успешно загружен"
    else
        log_status "Ошибка: не удалось загрузить образ"
        echo "Ошибка: не удалось загрузить образ $IMAGE_NAME"
        exit 1
    fi
fi

# === Пути ===
RUNTIME_DIR="/tmp/runtime-vdi"
AGENT_DIR="/tmp/.basis-vdi"
mkdir -p "$RUNTIME_DIR" && chmod 700 "$RUNTIME_DIR"
mkdir -p "$AGENT_DIR" && chmod 777 "$AGENT_DIR"

# === Формируем аргументы --dns ===
DNS_ARGS=""
for dns in "${DNS_SERVERS[@]}"; do
    DNS_ARGS="$DNS_ARGS --dns $dns"
done

# === Создаём директорию для конфига, если её нет ===
mkdir -p "$CONFIG_DIR"

# === Создаём шаблонный app-config, если его нет ===
if [ -f "$APP_CONFIG" ]; then
    log_status "Конфиг-файл найден: $APP_CONFIG"
else
    log_status "Создаём шаблонный app-config"
    cat > "$APP_CONFIG" << 'EOF'
{
  "AutoConnect": false,
  "brokers": ["sz-vpn.vdi.rt.gslb"],
  "rdp_client_path": "/usr/bin/xfreerdp",
  "stream_width": 4480,
  "stream_height": 1367,
  "xfreerdp_new_style_args": true,
  "remote_sound_mode": 2,
  "create_samba_shares": true,
  "samba_printers": false,
  "store_pin_code": true,
  "log_level": "INFO",
  "log_timezone": "Europe/Moscow",
  "rdp_client_extra_args": [
    "/clipboard"
  ],
  "samba_shares": [
    {
      "name": "share_dir",
      "path": "/home/vlad/Basis/share_dir",
      "read_only": false
    }
  ]
}
EOF
fi
# === Определяем временную зону хоста ===
HOST_TIMEZONE=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "Europe/Moscow")
log_status "Используем временную зону хоста: $HOST_TIMEZONE"

# === Запуск контейнера в фоне с пробросом конфига ===
log_status "Запуск контейнера в фоне: $CONTAINER_NAME"

DOCKER_RUN_CMD="docker run \
  --name '$CONTAINER_NAME' \
  --network host \
  $DNS_ARGS \
  -e DISPLAY \
  -e XDG_RUNTIME_DIR='$RUNTIME_DIR' \
  -e TZ='$HOST_TIMEZONE' \
  -v /etc/timezone:/etc/timezone:ro \
  -v /etc/localtime:/etc/localtime:ro \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  -v /tmp:/tmp \
  -v /dev/bus/usb:/dev/bus/usb \
  -v /run/user/$(id -u)/bus:/run/user/host/bus \
  --device /dev/usb/hiddev0 \
  -v '$CONFIG_DIR':/root/.vdi-client \
  '$IMAGE_NAME' \
  /bin/sh -c '
    echo \"[\$(date \\\"+%Y-%m-%d %H:%M:%S\\\")]\ Запуск\ desktop-agent-linux\" >> /tmp/container.log;
    /opt/vdi-client/bin/desktop-agent-linux > /tmp/agent.log 2>&1 & \
    sleep 1; \
    echo \"[\$(date \\\"+%Y-%m-%d %H:%M:%S\\\")]\ Запуск\ desktop-client\" >> /tmp/container.log; \
    exec /opt/vdi-client/bin/desktop-client
  '"

# Запускаем в фоне
nohup sh -c "$DOCKER_RUN_CMD" >> "$LOG_FILE" 2>&1 &

# === Финальное сообщение ===
echo
echo "Контейнер '$CONTAINER_NAME' запущен в фоне."
echo "Логи пишутся в: $LOG_FILE"
echo "Для просмотра: tail -f '$LOG_FILE'"
echo "Для остановки: docker stop $CONTAINER_NAME"
echo "Терминал можно закрыть — клиент продолжит работать."
