#!/bin/bash

# Выход при любой ошибке
set -e

# Цвета
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'


echo -e "${CYAN}=== Ультимативный скрипт настройки VPS ===${NC}"
echo -e "${CYAN}=== Remnanode + Self-Steal + Beszel + UFW + Fail2ban ===${NC}\n"


# ============================================================
# 1. Проверка прав root
# ============================================================

if [ "$EUID" -ne 0 ]; then
    echo "Пожалуйста, запустите скрипт от имени root."
    exit 1
fi


# ============================================================
# 2. GitHub token
# ============================================================

echo -e "${CYAN}--- GitHub ---${NC}"

# Если GITHUB_TOKEN уже передан через environment —
# используем его и ничего дополнительно не спрашиваем.
if [ -z "${GITHUB_TOKEN:-}" ]; then

    read -s -p "Введите GitHub token для доступа к private repo: " GITHUB_TOKEN
    echo ""

    if [ -z "$GITHUB_TOKEN" ]; then
        echo -e "${RED}Ошибка: GitHub token не может быть пустым!${NC}"
        exit 1
    fi

else

    echo -e "${GREEN}[+] GitHub token получен из environment.${NC}"

fi


# ============================================================
# 3. Сбор данных
# ============================================================

read -p "Введите имя нового пользователя [dj]: " USERNAME
USERNAME=${USERNAME:-dj}

read -s -p "Введите пароль для пользователя $USERNAME (для sudo): " USER_PASSWORD
echo ""

if [ -z "$USER_PASSWORD" ]; then
    echo -e "${YELLOW}Ошибка: пароль не может быть пустым!${NC}"
    exit 1
fi

read -p "Вставьте ваш публичный SSH-ключ для $USERNAME: " SSH_KEY

if [ -z "$SSH_KEY" ]; then
    echo -e "${YELLOW}Ошибка: SSH-ключ обязателен для безопасности!${NC}"
    exit 1
fi


# ============================================================
# 4. Получение docker-compose.yml Remnanode
# ============================================================

echo -e "\n${CYAN}--- Ввод конфигурации Docker Compose для Remnanode ---${NC}"
echo "Скопируйте docker-compose.yml из панели Remnawave."
echo -e "${YELLOW}Когда закончите вставку, нажмите Enter, затем Ctrl+D:${NC}"
echo "--------------------------------------------------------"

COMPOSE_CONTENT=$(cat)

if [ -z "$COMPOSE_CONTENT" ]; then
    echo -e "${YELLOW}Ошибка: конфигурация Docker Compose не может быть пустой!${NC}"
    exit 1
fi

echo "--------------------------------------------------------"
echo -e "${GREEN}Конфигурация Remnanode получена.${NC}"


# ============================================================
# 5. Обновление системы
# ============================================================

echo -e "\n${GREEN}[1/10] Обновление системы и установка базовых пакетов...${NC}"

apt update
apt upgrade -y
apt install -y curl git mc htop


# ============================================================
# 6. Создание пользователя
# ============================================================

echo -e "\n${GREEN}[2/10] Создание пользователя $USERNAME...${NC}"

if id "$USERNAME" &>/dev/null; then

    echo "Пользователь $USERNAME уже существует."
    echo "$USERNAME:$USER_PASSWORD" | chpasswd

else

    adduser --disabled-password --gecos "" "$USERNAME"

    echo "$USERNAME:$USER_PASSWORD" | chpasswd

    usermod -aG sudo "$USERNAME"

fi


# ============================================================
# 7. SSH
# ============================================================

echo -e "\n${GREEN}[3/10] Настройка SSH...${NC}"

USER_HOME="/home/$USERNAME"

mkdir -p "$USER_HOME/.ssh"

echo "$SSH_KEY" > "$USER_HOME/.ssh/authorized_keys"

chown -R "$USERNAME:$USERNAME" "$USER_HOME/.ssh"

chmod 700 "$USER_HOME/.ssh"
chmod 600 "$USER_HOME/.ssh/authorized_keys"


mkdir -p /etc/ssh/sshd_config.d

cat > /etc/ssh/sshd_config.d/99-security.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
KbdInteractiveAuthentication no
EOF


# Проверяем конфигурацию перед перезапуском
sshd -t

systemctl restart ssh

echo -e "${GREEN}[+] SSH настроен:${NC}"
echo "    Root login       = disabled"
echo "    Password auth    = disabled"
echo "    Public key       = enabled"


# ============================================================
# 8. Fail2ban
# ============================================================

echo -e "\n${GREEN}[4/10] Установка и настройка Fail2ban...${NC}"

apt install -y fail2ban

cat > /etc/fail2ban/jail.d/sshd.local <<'EOF'
[sshd]
enabled = true
maxretry = 4
bantime = 24h
findtime = 10m
EOF

systemctl enable --now fail2ban

echo -e "${GREEN}[+] Fail2ban настроен:${NC}"
echo "    maxretry = 4"
echo "    findtime = 10m"
echo "    bantime  = 24h"

fail2ban-client status sshd


# ============================================================
# 9. Docker
# ============================================================

echo -e "\n${GREEN}[5/10] Проверка и установка Docker...${NC}"

if ! command -v docker &> /dev/null; then

    curl -fsSL https://get.docker.com | sh

    echo "Docker установлен."

else

    echo "Docker уже установлен."

fi

# Добавляем пользователя в docker group
usermod -aG docker "$USERNAME"


# ============================================================
# 10. Beszel Agent
# ============================================================

echo -e "\n${GREEN}[6/10] Установка Beszel Agent...${NC}"

mkdir -p /opt/beszel-agent/beszel_agent_data

cat > /opt/beszel-agent/docker-compose.yml <<'EOF'
services:
  beszel-agent:
    image: henrygd/beszel-agent
    container_name: beszel-agent
    restart: unless-stopped
    network_mode: host

    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./beszel_agent_data:/var/lib/beszel-agent

    environment:
      LISTEN: 45876
      KEY: 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEAjMOpScy3OPQSphfInREBXjjKOlVFljJCGFbCtRX1X'
      TOKEN: '51c61117-1f36-47be-afcd-e7bbafbd3ad5'
      HUB_URL: 'https://beszel.technoblog.pro'
EOF

cd /opt/beszel-agent

docker compose pull
docker compose up -d

echo -e "${GREEN}[+] Beszel Agent успешно установлен.${NC}"


# ============================================================
# 11. Remnanode
# ============================================================

echo -e "\n${GREEN}[7/10] Установка и запуск Remnanode...${NC}"

mkdir -p /opt/remnanode

cd /opt/remnanode

echo "$COMPOSE_CONTENT" > docker-compose.yml

docker compose up -d

echo -e "${GREEN}[+] Remnanode запущен.${NC}"


# ============================================================
# 12. Генерация X25519
# ============================================================

echo -e "\n${GREEN}[8/10] Генерация ключей Xray (X25519)...${NC}"

sleep 3

CONTAINER_ID=$(docker ps -q -f "name=remnanode")

if [ -z "$CONTAINER_ID" ]; then
    CONTAINER_ID=$(docker ps -q -f "ancestor=remnawave/node")
fi

if [ -n "$CONTAINER_ID" ]; then

    echo -e "ID контейнера: ${CYAN}$CONTAINER_ID${NC}"
    echo "--------------------------------------------------------"

    docker exec "$CONTAINER_ID" xray x25519

    echo "--------------------------------------------------------"

else

    echo -e "${YELLOW}Предупреждение: контейнер Remnanode не найден.${NC}"

fi


# ============================================================
# 13. Self-Steal
# ============================================================

echo -e "\n${GREEN}[9/10] Настройка Self-Steal (Caddy)...${NC}"

read -p "Введите ваш домен для маскировки (например, lv.technoblog.pro): " DOMAIN_NAME

if [ -z "$DOMAIN_NAME" ]; then

    echo -e "${YELLOW}Домен не введен. Self-Steal пропускается.${NC}"

else

    mkdir -p /opt/selfsteal

    # --------------------------------------------------------
    # Caddyfile
    # --------------------------------------------------------

    cat > /opt/selfsteal/Caddyfile <<EOF
$DOMAIN_NAME {
    tls {
        protocols tls1.2 tls1.3
    }

    encode gzip
    root * /usr/share/caddy
    file_server
}
EOF

    echo "[-] Caddyfile создан."


    # --------------------------------------------------------
    # Загрузка Self-Steal из private full-node
    # --------------------------------------------------------

    echo "[-] Загрузка Self-Steal из private GitHub repository..."

    TMP_DIR=$(mktemp -d)

    cleanup_tmp() {
        rm -rf "$TMP_DIR"
    }

    trap cleanup_tmp EXIT


    echo "[-] Получение архива full-node..."

    curl -fsSL \
        -L \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/mrslaveg/full-node/tarball/main" \
        -o "$TMP_DIR/full-node.tar.gz"


    echo "[-] Распаковка full-node..."

    tar -xzf "$TMP_DIR/full-node.tar.gz" -C "$TMP_DIR"


    # GitHub создаёт каталог вида:
    # mrslaveg-full-node-<commit>
    REPO_DIR=$(find "$TMP_DIR" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -print -quit)


    if [ -z "$REPO_DIR" ]; then

        echo -e "${RED}Ошибка: каталог full-node не найден после распаковки.${NC}"
        exit 1

    fi


    echo "[-] Найден каталог:"
    echo "    $REPO_DIR"


    # --------------------------------------------------------
    # Проверяем структуру Self-Steal
    # --------------------------------------------------------

    if [ ! -d "$REPO_DIR/selfsteal" ]; then

        echo -e "${RED}Ошибка: каталог selfsteal отсутствует в full-node.${NC}"
        exit 1

    fi


    if [ ! -f "$REPO_DIR/selfsteal/docker-compose.yml" ]; then

        echo -e "${RED}Ошибка: selfsteal/docker-compose.yml отсутствует.${NC}"
        exit 1

    fi


    # --------------------------------------------------------
    # Копируем docker-compose.yml
    # --------------------------------------------------------

    cp "$REPO_DIR/selfsteal/docker-compose.yml" \
       /opt/selfsteal/docker-compose.yml


    # --------------------------------------------------------
    # Копируем site
    # --------------------------------------------------------

    rm -rf /opt/selfsteal/site

    if [ -d "$REPO_DIR/selfsteal/site" ]; then

        cp -r "$REPO_DIR/selfsteal/site" \
              /opt/selfsteal/

    else

        echo -e "${YELLOW}Предупреждение: папка site не найдена.${NC}"
        mkdir -p /opt/selfsteal/site

    fi


    # --------------------------------------------------------
    # Удаляем временные файлы
    # --------------------------------------------------------

    rm -rf "$TMP_DIR"

    trap - EXIT


    # --------------------------------------------------------
    # Удаляем GitHub token из environment
    # --------------------------------------------------------

    unset GITHUB_TOKEN


    # --------------------------------------------------------
    # Запуск Caddy
    # --------------------------------------------------------

    cd /opt/selfsteal

    docker compose pull
    docker compose up -d

    echo -e "${GREEN}[+] Self-Steal успешно запущен.${NC}"
    echo "    Домен: $DOMAIN_NAME"

fi


# ============================================================
# 14. UFW
# ============================================================

echo -e "\n${GREEN}[10/10] Настройка UFW...${NC}"

if ! command -v ufw &> /dev/null; then

    echo "[-] Установка UFW..."

    apt install -y ufw

else

    echo "[-] UFW уже установлен."

fi


# ------------------------------------------------------------
# Отключение IPv6 в UFW
# ------------------------------------------------------------

echo "[-] Отключение IPv6 в UFW..."

if [ -f /etc/default/ufw ]; then
    sed -i 's/^IPV6=yes/IPV6=no/' /etc/default/ufw
fi


# ------------------------------------------------------------
# Сброс старых правил
# ------------------------------------------------------------

echo "[-] Сброс правил UFW..."

echo y | ufw reset

ufw default deny incoming
ufw default allow outgoing


# ------------------------------------------------------------
# Основные порты
# ------------------------------------------------------------

echo "[-] Разрешение SSH..."

ufw allow ssh


# HTTP нужен Caddy для HTTP → HTTPS redirect
echo "[-] Разрешение HTTP..."

ufw allow http


# HTTPS
echo "[-] Разрешение HTTPS..."

ufw allow https


# ------------------------------------------------------------
# Remnawave Node
# ------------------------------------------------------------

echo "[-] Разрешение Remnawave Node :2222 только для 89.127.203.170..."

ufw allow from 89.127.203.170 \
    to any port 2222 proto tcp


# ------------------------------------------------------------
# Beszel Agent
# ------------------------------------------------------------

echo "[-] Разрешение Beszel Agent :45876 только для 217.177.44.148..."

ufw allow from 217.177.44.148 \
    to any port 45876 proto tcp


# ------------------------------------------------------------
# Включение UFW
# ------------------------------------------------------------

echo "[-] Включение UFW..."

echo y | ufw enable

ufw reload

echo -e "${GREEN}[+] UFW успешно настроен.${NC}"


# ============================================================
# 15. Финальная проверка
# ============================================================

echo -e "\n${CYAN}========================================================${NC}"
echo -e "${CYAN}             ФИНАЛЬНАЯ ПРОВЕРКА СИСТЕМЫ${NC}"
echo -e "${CYAN}========================================================${NC}"


# ------------------------------------------------------------
# SSH
# ------------------------------------------------------------

echo -e "\n${CYAN}--- SSH ---${NC}"

sshd -T | grep -E \
    'permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication'


# ------------------------------------------------------------
# Fail2ban
# ------------------------------------------------------------

echo -e "\n${CYAN}--- Fail2ban ---${NC}"

fail2ban-client status

echo "--------------------------------------------------------"

fail2ban-client status sshd


# ------------------------------------------------------------
# Docker
# ------------------------------------------------------------

echo -e "\n${CYAN}--- Docker containers ---${NC}"

docker ps --format \
    'table {{.Names}}\t{{.Status}}\t{{.Ports}}'


# ------------------------------------------------------------
# Beszel Agent
# ------------------------------------------------------------

echo -e "\n${CYAN}--- Beszel Agent ---${NC}"

docker ps \
    --filter "name=beszel-agent" \
    --format 'table {{.Names}}\t{{.Status}}'

echo "--------------------------------------------------------"

if ss -lnt | grep -q ':45876 '; then

    echo -e "${GREEN}[+] Beszel Agent слушает порт 45876.${NC}"

else

    echo -e "${YELLOW}[!] Beszel Agent не найден на порту 45876.${NC}"

fi


# ------------------------------------------------------------
# UFW
# ------------------------------------------------------------

echo -e "\n${CYAN}--- UFW ---${NC}"

ufw status verbose


# ------------------------------------------------------------
# Открытые порты
# ------------------------------------------------------------

echo -e "\n${CYAN}--- Открытые TCP/UDP порты ---${NC}"

ss -lntup


echo -e "\n${CYAN}========================================================${NC}"
echo -e "${GREEN}       ВСЕ КОМПОНЕНТЫ НАСТРОЕНЫ И ЗАПУЩЕНЫ!${NC}"
echo -e "${CYAN}========================================================${NC}"


echo -e "\n${YELLOW}ВАЖНО:${NC}"
echo "Откройте НОВОЕ окно терминала и проверьте SSH:"
echo -e "${CYAN}ssh $USERNAME@<IP_СЕРВЕРА>${NC}"

echo "Не закрывайте текущую SSH-сессию, пока не убедитесь,"
echo "что вход по новому пользователю и ключу работает."

echo "--------------------------------------------------------"


# ============================================================
# 16. Логи Self-Steal
# ============================================================

if [ -d "/opt/selfsteal" ] && \
   [ -f "/opt/selfsteal/docker-compose.yml" ]; then

    read -p "Показать логи Caddy/Self-Steal прямо сейчас? (y/n): " SHOW_LOGS

    if [[ "$SHOW_LOGS" == "y" || "$SHOW_LOGS" == "Y" ]]; then

        echo -e "${CYAN}Для выхода из логов нажмите Ctrl+C${NC}"

        sleep 2

        cd /opt/selfsteal

        docker compose logs -f -t

    fi

else

    echo -e "${YELLOW}Self-Steal не установлен — просмотр логов пропущен.${NC}"

fi


# ============================================================
# 17. Перезагрузка
# ============================================================

echo ""

read -p "Перезагрузить сервер сейчас для применения обновлений? (y/n): " REBOOT_NOW

if [[ "$REBOOT_NOW" == "y" || "$REBOOT_NOW" == "Y" ]]; then

    echo "Перезагрузка..."

    reboot

fi
```
