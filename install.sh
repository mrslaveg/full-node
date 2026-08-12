#!/bin/bash

# Выход при любой ошибке
set -e

# Цвета для красивого вывода
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${CYAN}=== Ультимативный скрипт настройки VPS: Remnanode + Self-Steal + UFW + Fail2ban ===${NC}\n"

# 1. Проверка прав root

if [ "$EUID" -ne 0 ]; then
    echo "Пожалуйста, запустите скрипт от имени root (sudo bash -c ...)"
    exit 1
fi

# 2. Интерактивный сбор данных для системы

read -p "Введите имя нового пользователя [dj]: " USERNAME
USERNAME=${USERNAME:-dj}

# Запрашиваем пароль (ввод скрыт для безопасности)

read -s -p "Введите пароль для пользователя $USERNAME (для sudo): " USER_PASSWORD
echo ""

if [ -z "$USER_PASSWORD" ]; then
    echo -e "${YELLOW}Ошибка: Пароль не может быть пустым!${NC}"
    exit 1
fi

read -p "Вставьте ваш публичный SSH-ключ для $USERNAME: " SSH_KEY

if [ -z "$SSH_KEY" ]; then
    echo -e "${YELLOW}Ошибка: SSH-ключ обязателен для безопасности!${NC}"
    exit 1
fi

# 3. Сбор содержимого docker-compose.yml для Remnanode

echo -e "\n${CYAN}--- Ввод конфигурации Docker Compose для Remnanode ---${NC}"
echo "Скопируйте текст docker-compose.yml из панели Remnawave."
echo -e "${YELLOW}Вставьте его ниже. Когда закончите, нажмите Enter, затем Ctrl+D:${NC}"
echo "--------------------------------------------------------"

COMPOSE_CONTENT=$(cat)

if [ -z "$COMPOSE_CONTENT" ]; then
    echo -e "${YELLOW}Ошибка: Конфигурация Docker Compose не может быть пустой!${NC}"
    exit 1
fi

echo "--------------------------------------------------------"
echo -e "${GREEN}Конфигурация Remnanode получена.${NC}"

# 4. Обновление системы и установка базового софта

echo -e "\n${GREEN}[1/9] Обновление пакетов и установка базовых утилит (curl, git, mc, htop)...${NC}"

apt update
apt upgrade -y
apt install -y curl git mc htop

# 5. Создание пользователя и добавление в sudo

echo -e "\n${GREEN}[2/9] Создание пользователя $USERNAME...${NC}"

if id "$USERNAME" &>/dev/null; then
    echo "Пользователь $USERNAME уже существует. Обновляем ему пароль."
    echo "$USERNAME:$USER_PASSWORD" | chpasswd
else
    adduser --disabled-password --gecos "" "$USERNAME"

    # Устанавливаем введенный пароль
    echo "$USERNAME:$USER_PASSWORD" | chpasswd

    usermod -aG sudo "$USERNAME"
fi

# 6. Настройка SSH-ключей

echo -e "\n${GREEN}[3/9] Добавление SSH-ключей...${NC}"

USER_HOME="/home/$USERNAME"

mkdir -p "$USER_HOME/.ssh"

echo "$SSH_KEY" > "$USER_HOME/.ssh/authorized_keys"

chown -R "$USERNAME:$USERNAME" "$USER_HOME/.ssh"

chmod 700 "$USER_HOME/.ssh"
chmod 600 "$USER_HOME/.ssh/authorized_keys"

# 7. Безопасность SSH через sshd_config.d/*.conf

echo -e "\n${GREEN}[4/9] Настройка безопасности SSH (sshd_config.d)...${NC}"

mkdir -p /etc/ssh/sshd_config.d

cat > /etc/ssh/sshd_config.d/99-security.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
KbdInteractiveAuthentication no
EOF

# Проверяем конфигурацию SSH перед перезапуском
sshd -t

systemctl restart ssh

echo "SSH успешно настроен."
echo "Root-вход и вход по паролю отключены."

# 4.1. Установка и настройка Fail2ban

echo -e "\n${GREEN}[4.1/9] Установка и настройка Fail2ban для защиты SSH...${NC}"

apt install -y fail2ban

cat > /etc/fail2ban/jail.d/sshd.local <<'EOF'
[sshd]
enabled = true
maxretry = 4
bantime = 24h
findtime = 10m
EOF

systemctl enable --now fail2ban

echo "[-] Проверка Fail2ban..."

fail2ban-client status sshd

echo -e "${GREEN}[+] Fail2ban успешно настроен:${NC}"
echo "    4 неудачные попытки"
echo "    окно: 10 минут"
echo "    бан: 24 часа"

# 8. Установка Docker

echo -e "\n${GREEN}[5/9] Проверка и установка Docker...${NC}"

if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | sh

    usermod -aG docker "$USERNAME"

    echo "Docker установлен."
else
    echo "Docker уже присутствует в системе."

    # На случай, если пользователь уже существовал
    usermod -aG docker "$USERNAME"
fi

# 9. Создание директории и запуск ноды Remnanode

echo -e "\n${GREEN}[6/9] Запись конфигурации и запуск ноды...${NC}"

mkdir -p /opt/remnanode

cd /opt/remnanode

echo "$COMPOSE_CONTENT" > docker-compose.yml

docker compose up -d

# Шаг генерации ключей Xray

sleep 3

echo -e "\n${GREEN}[7/9] Генерация ключей Xray (X25519)...${NC}"

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

    echo -e "${YELLOW}Предупреждение: Контейнер ноды не найден для генерации ключей.${NC}"

fi

# 10. Установка Self-Steal (Caddy + Сайт)

echo -e "\n${GREEN}[8/9] Настройка Self-Steal (Маскировка Caddy)...${NC}"

read -p "Введите ваш домен для маскировки (например, lv.technoblog.pro): " DOMAIN_NAME

if [ -z "$DOMAIN_NAME" ]; then

    echo -e "${YELLOW}Домен не введен. Пропускаем развертывание Self-Steal.${NC}"

else

    # Создаем корневую директорию для selfsteal
    mkdir -p /opt/selfsteal

    # 10.1. Генерируем Caddyfile

    cat << EOF > /opt/selfsteal/Caddyfile
$DOMAIN_NAME {
    tls {
        protocols tls1.2 tls1.3
    }

    encode gzip
    root * /usr/share/caddy
    file_server
}
EOF

    echo "[-] Caddyfile успешно сгенерирован."

    # 10.2. Скачиваем структуру из репозитория с учетом подпапки selfsteal

    echo "[-] Загрузка структуры Self-Steal из GitHub..."

    TMP_DIR=$(mktemp -d)

    git clone --depth 1 https://github.com/mrslaveg/selfsteal.git "$TMP_DIR"

    REPO_SUBDIR="$TMP_DIR/selfsteal"

    if [ -d "$REPO_SUBDIR" ]; then

        # Копируем docker-compose.yml из подпапки selfsteal

        if [ -f "$REPO_SUBDIR/docker-compose.yml" ]; then
            cp "$REPO_SUBDIR/docker-compose.yml" /opt/selfsteal/docker-compose.yml

        elif [ -f "$REPO_SUBDIR/Docker-compose.yml" ]; then
            cp "$REPO_SUBDIR/Docker-compose.yml" /opt/selfsteal/docker-compose.yml 2>/dev/null || true
        fi

        # Копируем папку site целиком

        if [ -d "$REPO_SUBDIR/site" ]; then
            cp -r "$REPO_SUBDIR/site" /opt/selfsteal/

        else
            echo -e "${YELLOW}Предупреждение: Папка 'site' не найдена внутри подпапки selfsteal!${NC}"
            mkdir -p /opt/selfsteal/site
        fi

    else

        echo -e "${YELLOW}Предупреждение: Подпапка 'selfsteal' не найдена в репо. Пробуем корень...${NC}"

        cp "$TMP_DIR/docker-compose.yml" /opt/selfsteal/docker-compose.yml 2>/dev/null || true

        cp -r "$TMP_DIR/site" /opt/selfsteal/ 2>/dev/null || mkdir -p /opt/selfsteal/site

    fi

    rm -rf "$TMP_DIR"

    echo "[-] Файлы сайта и docker-compose.yml успешно размещены в /opt/selfsteal/"

    # 10.3. Запуск Caddy (Self-Steal)

    echo -e "[-] Запуск контейнеров Self-Steal..."

    cd /opt/selfsteal

    docker compose up -d

    echo -e "${GREEN}[+] Self-Steal успешно поднят и защищает домен $DOMAIN_NAME!${NC}"

fi

# 11. Настройка файрвола UFW и отключение IPv6

echo -e "\n${GREEN}[9/9] Настройка файрвола UFW и безопасности сети...${NC}"

if ! command -v ufw &> /dev/null; then

    echo "[-] UFW не найден. Установка..."

    apt update
    apt install -y ufw

else

    echo "[-] UFW уже установлен."

fi

echo "[-] Отключение IPv6 в настройках UFW..."

if [ -f /etc/default/ufw ]; then
    sed -i 's/IPV6=yes/IPV6=no/' /etc/default/ufw
fi

echo "[-] Применение правил файрвола..."

echo y | ufw reset

ufw default deny incoming
ufw default allow outgoing

# Разрешаем необходимые порты

ufw allow ssh
ufw allow http
ufw allow https

# Доверенный IP для Remnawave Node

ufw allow from 89.127.203.170 to any port 2222 proto tcp

# Доверенный IP для agent

ufw allow from 217.177.44.148 to any port 45876 proto tcp

# Включаем и перезагружаем файрвол

echo y | ufw enable

ufw reload

echo -e "${GREEN}[+] Файрвол UFW успешно настроен!${NC}"

# Финальная проверка безопасности

echo -e "\n${CYAN}=== ПРОВЕРКА БЕЗОПАСНОСТИ ===${NC}"

echo "--------------------------------------------------------"

echo -e "${CYAN}SSH:${NC}"
sshd -T | grep -E 'permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication'

echo "--------------------------------------------------------"

echo -e "${CYAN}Fail2ban:${NC}"
fail2ban-client status
echo "--------------------------------------------------------"
fail2ban-client status sshd

echo "--------------------------------------------------------"

echo -e "${CYAN}UFW:${NC}"
ufw status verbose

echo "--------------------------------------------------------"

echo -e "${CYAN}Открытые TCP/UDP порты:${NC}"
ss -lntup

echo "--------------------------------------------------------"

echo -e "${GREEN}=== ВСЕ КОМПОНЕНТЫ НАСТРОЕНЫ И ЗАПУЩЕНЫ! ===${NC}"

echo -e "${YELLOW}ВНИМАНИЕ:${NC} Откройте НОВОЕ окно терминала и проверьте доступ:"
echo -e "${CYAN}ssh $USERNAME@<IP_СЕРВЕРА>${NC} по вашему ключу перед закрытием этой сессии!"

echo "--------------------------------------------------------"

# Финальный просмотр логов на выбор

read -p "Показать логи Caddy/Self-Steal прямо сейчас? (y/n): " SHOW_LOGS

if [[ "$SHOW_LOGS" == "y" || "$SHOW_LOGS" == "Y" ]]; then

    echo -e "${CYAN}Для выхода из логов нажмите Ctrl+C${NC}"

    sleep 2

    cd /opt/selfsteal
    docker compose logs -f -t

fi

echo ""

read -p "Перезагрузить сервер сейчас для применения обновлений ядра/пакетов? (y/n): " REBOOT_NOW

if [[ "$REBOOT_NOW" == "y" || "$REBOOT_NOW" == "Y" ]]; then

    echo "Перезагрузка..."

    reboot

fi
