#!/bin/bash

# Выход при любой ошибке
set -e

# Цвета для красивого вывода
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${CYAN}=== Ультимативный скрипт настройки VPS: Remnanode + Self-Steal + UFW ===${NC}\n"

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
echo "" # Перенос строки после скрытого ввода

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
apt update && apt upgrade -y
# Ставим всё необходимое разом
apt install -y curl git mc htop

# 5. Создание пользователя и добавление в sudo
echo -e "\n${GREEN}[2/9] Создание пользователя $USERNAME...${NC}"
if id "$USERNAME" &>/dev/null; then
    echo "Пользователь $USERNAME уже существует. Обновляем ему пароль."
    echo "$USERNAME:$USER_PASSWORD" | chpasswd
else
    adduser --disabled-password --gecos "" $USERNAME
    # Устанавливаем твой введенный пароль
    echo "$USERNAME:$USER_PASSWORD" | chpasswd
    usermod -aG sudo $USERNAME
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
cat << 'EOF' > /etc/ssh/sshd_config.d/99-security.conf
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
EOF
systemctl restart ssh
echo "SSH успешно настроен. Доступ root и по паролю заблокирован."

# 8. Установка Docker
echo -e "\n${GREEN}[5/9] Проверка и установка Docker...${NC}"
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | sh
    usermod -aG docker $USERNAME
    echo "Docker установлен."
else
    echo "Docker уже присутствует в системе."
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

    # 10.2. Скачиваем структуру из репозитория
    echo "[-] Загрузка структуры Self-Steal из GitHub..."
    TMP_DIR=$(mktemp -d)
    git clone --depth 1 https://github.com/mrslaveg/selfsteal.git "$TMP_DIR"
    
    cp "$TMP_DIR/docker-compose.yml" /opt/selfsteal/docker-compose.yml
    cp -r "$TMP_DIR/site" /opt/selfsteal/
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
    apt update && apt install ufw -y
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

# Разрешаем порты
ufw allow ssh
ufw allow http
ufw allow https

# Доверенный IP для порта 2222
ufw allow from 89.127.203.170 to any port 2222 proto tcp

# Включаем и перезагружаем
echo y | ufw enable
ufw reload
echo -e "${GREEN}[+] Файрвол UFW успешно настроен!${NC}"

echo -e "\n${GREEN}=== ВСЕ КОМПОНЕНТЫ НАСТРОЕНЫ И ЗАПУЩЕНЫ! ===${NC}"
echo -e "${YELLOW}ВНИМАНИЕ:${NC} Откройте НОВОЕ окно терминала и проверьте доступ:"
echo -e "${CYAN}ssh $USERNAME@<IP_СЕРВЕРА>${NC} по вашему ключу перед закрытием этой сессии!"
echo "--------------------------------------------------------"
ufw status verbose
echo "--------------------------------------------------------"

# Финальный просмотр логов на выбор
read -p "Показать логи Caddy/Self-Steal прямо сейчас? (y/n): " SHOW_LOGS
if [[ "$SHOW_LOGS" == "y" || "$SHOW_LOGS" == "Y" ]]; then
    echo -e "${CYAN}Для выхода из логов нажмите Ctrl+C${NC}"
    sleep 2
    cd /opt/selfsteal && docker compose logs -f -t
fi

echo ""
read -p "Перезагрузить сервер сейчас для применения обновлений ядра/пакетов? (y/n): " REBOOT_NOW
if [[ "$REBOOT_NOW" == "y" || "$REBOOT_NOW" == "Y" ]]; then
    echo "Перезагрузка..."
    reboot
fi
