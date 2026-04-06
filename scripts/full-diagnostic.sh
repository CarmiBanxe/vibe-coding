#!/bin/bash
###############################################################################
# full-diagnostic.sh — Полная диагностика GMKtec + Legion
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/full-diagnostic.sh
#
# Результат сохраняется в ~/vibe-coding/docs/diagnostic-report.md
###############################################################################

REPORT="/tmp/diagnostic-report.md"
GMKTEC_IP="192.168.0.72"
GMKTEC_PORT="2222"

echo "=========================================="
echo "  ПОЛНАЯ ДИАГНОСТИКА ИНФРАСТРУКТУРЫ"
echo "=========================================="

cat > "$REPORT" << 'HEADER'
# Диагностический отчёт инфраструктуры Banxe AI Bank
> Дата генерации: DATEPLACEHOLDER
> Скрипт: full-diagnostic.sh

---

HEADER

sed -i "s/DATEPLACEHOLDER/$(date '+%Y-%m-%d %H:%M:%S %Z')/" "$REPORT"

###############################################################################
# ЧАСТЬ 1: ДИАГНОСТИКА LEGION
###############################################################################

echo ""
echo "╔══════════════════════════════════════╗"
echo "║   ЧАСТЬ 1: LEGION (mark-legion)      ║"
echo "╚══════════════════════════════════════╝"

{
echo "## ЧАСТЬ 1: LEGION (mark-legion)"
echo ""

# --- 1.1 Общая информация ---
echo "### 1.1 Система"
echo '```'
echo "Hostname: $(hostname)"
echo "OS: $(lsb_release -d 2>/dev/null | cut -f2 || cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')"
echo "Kernel: $(uname -r)"
echo "Uptime: $(uptime -p)"
echo "User: $(whoami)"
echo "Date: $(date)"
echo '```'
echo ""

# --- 1.2 CPU ---
echo "### 1.2 CPU"
echo '```'
lscpu | grep -E "Model name|CPU\(s\)|Thread|Core|MHz|Architecture" 2>/dev/null || echo "lscpu не доступен"
echo '```'
echo ""

# --- 1.3 RAM ---
echo "### 1.3 RAM"
echo '```'
free -h
echo '```'
echo ""

# --- 1.4 Диски ---
echo "### 1.4 Диски"
echo '```'
df -h | grep -E "Filesystem|/dev/|/mnt/" | head -20
echo ""
echo "Блочные устройства:"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null || df -h
echo '```'
echo ""

# --- 1.5 Сеть ---
echo "### 1.5 Сеть"
echo '```'
echo "IP адреса:"
ip -4 addr show 2>/dev/null | grep inet | awk '{print $NF": "$2}' || hostname -I
echo ""
echo "Default gateway:"
ip route | grep default 2>/dev/null || echo "Не определён"
echo '```'
echo ""

# --- 1.6 Сервисы systemd (user) ---
echo "### 1.6 Сервисы systemd (user)"
echo '```'
systemctl --user list-units --type=service --all 2>/dev/null | grep -E "openclaw|litellm|loaded|active" | head -20 || echo "systemd --user не доступен"
echo '```'
echo ""

# --- 1.7 OpenClaw ---
echo "### 1.7 OpenClaw"
echo '```'
echo "Версия:"
openclaw --version 2>/dev/null || echo "openclaw не найден"
echo ""
echo "Профили:"
ls -la ~/.openclaw*/openclaw.json 2>/dev/null || echo "Нет конфигов"
echo ""
echo "Gateway статус:"
systemctl --user status openclaw-gateway-moa 2>/dev/null | head -10 || echo "Сервис не найден"
echo '```'
echo ""

# --- 1.8 LiteLLM ---
echo "### 1.8 LiteLLM"
echo '```'
echo "Версия:"
litellm --version 2>/dev/null || echo "litellm не найден"
echo ""
echo "Статус сервиса:"
systemctl --user status litellm 2>/dev/null | head -10 || echo "Сервис не найден"
echo ""
echo "Конфиг:"
cat ~/litellm-config.yaml 2>/dev/null | grep -E "model_name|model:" | head -20 || echo "Конфиг не найден"
echo '```'
echo ""

# --- 1.9 Порты ---
echo "### 1.9 Слушающие порты"
echo '```'
ss -tlnp 2>/dev/null | grep -E "LISTEN|State" | head -20 || netstat -tlnp 2>/dev/null | head -20
echo '```'
echo ""

# --- 1.10 SSH ключи ---
echo "### 1.10 SSH ключи и конфиг"
echo '```'
ls -la ~/.ssh/*.pub 2>/dev/null || echo "Нет публичных ключей"
echo ""
echo "SSH config:"
cat ~/.ssh/config 2>/dev/null | head -20 || echo "Нет SSH config"
echo ""
echo "Алиасы:"
grep -E "alias gmk|alias ssh" ~/.bashrc 2>/dev/null || echo "Нет алиасов"
echo '```'
echo ""

# --- 1.11 Git/GitHub ---
echo "### 1.11 Git репозитории"
echo '```'
echo "vibe-coding:"
ls -la ~/vibe-coding/.git 2>/dev/null && echo "OK" || echo "Не найден"
echo ""
echo "OpenClaw workspace:"
ls -la ~/.openclaw-moa/workspace-moa/.git 2>/dev/null && echo "OK (git init)" || echo "Нет git"
echo '```'
echo ""

# --- 1.12 Python/Node ---
echo "### 1.12 Runtime"
echo '```'
echo "Node.js: $(node --version 2>/dev/null || echo 'не установлен')"
echo "npm: $(npm --version 2>/dev/null || echo 'не установлен')"
echo "Python3: $(python3 --version 2>/dev/null || echo 'не установлен')"
echo "pip3: $(pip3 --version 2>/dev/null | head -1 || echo 'не установлен')"
echo "pipx: $(pipx --version 2>/dev/null || echo 'не установлен')"
echo '```'
echo ""

} >> "$REPORT"

echo "  ✓ Legion диагностика завершена"

###############################################################################
# ЧАСТЬ 2: ДИАГНОСТИКА GMKtec
###############################################################################

echo ""
echo "╔══════════════════════════════════════╗"
echo "║   ЧАСТЬ 2: GMKtec (EVO-X2)          ║"
echo "╚══════════════════════════════════════╝"
echo ""
echo "Подключаюсь к GMKtec ($GMKTEC_IP:$GMKTEC_PORT)..."
echo "Введи пароль root (mmber) когда попросит."
echo ""

{
echo "## ЧАСТЬ 2: GMKtec EVO-X2 (AI Compute Brain)"
echo ""
} >> "$REPORT"

ssh -p "$GMKTEC_PORT" "root@$GMKTEC_IP" 'bash -s' << 'GMKTEC_DIAG' >> "$REPORT" 2>&1

# --- 2.1 Общая информация ---
echo "### 2.1 Система"
echo '```'
echo "Hostname: $(hostname)"
echo "OS: $(lsb_release -d 2>/dev/null | cut -f2 || cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')"
echo "Kernel: $(uname -r)"
echo "Uptime: $(uptime -p)"
echo "User: $(whoami)"
echo "Date: $(date)"
echo "Boot mode: $([ -d /sys/firmware/efi ] && echo 'UEFI' || echo 'BIOS')"
echo '```'
echo ""

# --- 2.2 CPU ---
echo "### 2.2 CPU"
echo '```'
lscpu | grep -E "Model name|CPU\(s\)|Thread|Core|MHz|Architecture" 2>/dev/null
echo '```'
echo ""

# --- 2.3 RAM ---
echo "### 2.3 RAM"
echo '```'
free -h
echo ""
echo "Детали модулей:"
dmidecode -t memory 2>/dev/null | grep -E "Size:|Type:|Speed:" | head -10 || echo "dmidecode не доступен"
echo '```'
echo ""

# --- 2.4 GPU ---
echo "### 2.4 GPU"
echo '```'
echo "Видеокарты (lspci):"
lspci 2>/dev/null | grep -i vga || echo "lspci не доступен"
echo ""
echo "DRM info:"
cat /sys/class/drm/card*/device/mem_info_vram_total 2>/dev/null && echo " bytes VRAM" || echo "DRM VRAM info не доступен"
echo ""
echo "ROCm (AMD GPU):"
rocm-smi 2>/dev/null | head -20 || echo "rocm-smi не установлен"
echo ""
echo "Vulkan:"
vulkaninfo --summary 2>/dev/null | head -10 || echo "vulkaninfo не установлен"
echo '```'
echo ""

# --- 2.5 Диски (КЛЮЧЕВОЙ РАЗДЕЛ) ---
echo "### 2.5 Диски (подробно)"
echo '```'
echo "=== Блочные устройства ==="
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL
echo ""
echo "=== Использование файловых систем ==="
df -h | grep -E "Filesystem|/dev/"
echo ""
echo "=== Все разделы ==="
fdisk -l 2>/dev/null | grep -E "Disk /dev/|Device|/dev/nvme|/dev/sd" | head -30
echo ""
echo "=== NVMe устройства ==="
nvme list 2>/dev/null || ls -la /dev/nvme* 2>/dev/null | head -10 || echo "nvme не установлен"
echo ""
echo "=== Монтирование ==="
mount | grep -E "/dev/nvme|/dev/sd" | head -10
echo ""
echo "=== fstab ==="
cat /etc/fstab
echo '```'
echo ""

# --- 2.6 Сеть ---
echo "### 2.6 Сеть"
echo '```'
echo "IP адреса:"
ip -4 addr show 2>/dev/null | grep -E "inet |^[0-9]" | head -20
echo ""
echo "Default gateway:"
ip route | grep default 2>/dev/null
echo ""
echo "DNS:"
cat /etc/resolv.conf 2>/dev/null | grep -v "^#"
echo ""
echo "Firewall (ufw):"
ufw status 2>/dev/null || echo "ufw не установлен"
echo ""
echo "fail2ban:"
fail2ban-client status 2>/dev/null || echo "fail2ban не установлен"
echo '```'
echo ""

# --- 2.7 SSH ---
echo "### 2.7 SSH"
echo '```'
echo "SSH порт:"
grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null || echo "Порт по умолчанию (22)"
echo ""
echo "PermitRootLogin:"
grep -E "^PermitRootLogin" /etc/ssh/sshd_config 2>/dev/null || echo "Не задано"
echo ""
echo "SSH слушает:"
ss -tlnp | grep ssh
echo '```'
echo ""

# --- 2.8 Ollama ---
echo "### 2.8 Ollama"
echo '```'
echo "Версия:"
ollama --version 2>/dev/null || echo "Не установлен"
echo ""
echo "Статус сервиса:"
systemctl status ollama 2>/dev/null | head -10 || echo "Сервис не найден"
echo ""
echo "Модели:"
ollama list 2>/dev/null || echo "Не доступен"
echo ""
echo "Конфиг (env):"
grep -r "OLLAMA" /etc/systemd/system/ollama.service 2>/dev/null || echo "Нет кастомных переменных"
echo ""
echo "Порт:"
ss -tlnp | grep 11434
echo ""
echo "GPU использование Ollama:"
ollama ps 2>/dev/null || echo "Нет активных моделей"
echo '```'
echo ""

# --- 2.9 ClickHouse ---
echo "### 2.9 ClickHouse"
echo '```'
echo "Версия:"
clickhouse-client --version 2>/dev/null || echo "Не установлен"
echo ""
echo "Статус:"
systemctl status clickhouse-server 2>/dev/null | head -10 || echo "Сервис не найден"
echo ""
echo "Базы данных:"
clickhouse-client --query "SHOW DATABASES" 2>/dev/null || echo "Не доступен"
echo ""
echo "Таблицы banxe:"
clickhouse-client --query "SHOW TABLES FROM banxe" 2>/dev/null || echo "База banxe не найдена"
echo ""
echo "Порты:"
ss -tlnp | grep -E "9000|8123"
echo '```'
echo ""

# --- 2.10 Docker ---
echo "### 2.10 Docker"
echo '```'
docker --version 2>/dev/null || echo "Не установлен"
docker ps -a 2>/dev/null || echo ""
echo '```'
echo ""

# --- 2.11 OpenClaw на GMKtec ---
echo "### 2.11 OpenClaw (на GMKtec)"
echo '```'
echo "Версия:"
openclaw --version 2>/dev/null || echo "Не установлен"
echo ""
echo "Профили:"
ls -la /home/*/.openclaw*/openclaw.json /root/.openclaw*/openclaw.json 2>/dev/null || echo "Нет профилей"
echo ""
echo "Node.js: $(node --version 2>/dev/null || echo 'не установлен')"
echo "npm: $(npm --version 2>/dev/null || echo 'не установлен')"
echo "Python3: $(python3 --version 2>/dev/null || echo 'не установлен')"
echo '```'
echo ""

# --- 2.12 Пользователи ---
echo "### 2.12 Пользователи"
echo '```'
echo "Системные пользователи с shell:"
grep -E "/bin/(ba)?sh$" /etc/passwd
echo ""
echo "Домашние директории:"
ls -la /home/
echo '```'
echo ""

# --- 2.13 Сервисы ---
echo "### 2.13 Активные сервисы"
echo '```'
systemctl list-units --type=service --state=active 2>/dev/null | grep -E "ollama|click|ssh|xrdp|fail2ban|nginx|docker|openclaw|litellm|cron" | head -20
echo '```'
echo ""

# --- 2.14 Слушающие порты ---
echo "### 2.14 Все слушающие порты"
echo '```'
ss -tlnp | grep LISTEN
echo '```'
echo ""

# --- 2.15 Температура и нагрузка ---
echo "### 2.15 Нагрузка и температура"
echo '```'
echo "Load average: $(cat /proc/loadavg)"
echo ""
echo "Top процессы по RAM:"
ps aux --sort=-%mem | head -10
echo ""
echo "Температура:"
sensors 2>/dev/null | head -20 || echo "sensors не установлен"
echo '```'
echo ""

# --- 2.16 Crontab ---
echo "### 2.16 Crontab"
echo '```'
crontab -l 2>/dev/null || echo "Нет crontab для root"
echo ""
echo "Crontab banxe:"
crontab -l -u banxe 2>/dev/null || echo "Нет crontab для banxe"
echo '```'
echo ""

# --- 2.17 Windows (если доступен второй диск) ---
echo "### 2.17 Windows диск (2TB)"
echo '```'
echo "Поиск Windows разделов:"
fdisk -l 2>/dev/null | grep -i "microsoft\|ntfs\|windows" || echo "Windows разделы не найдены через fdisk"
echo ""
echo "NTFS разделы:"
blkid 2>/dev/null | grep -i ntfs || echo "NTFS не найден через blkid"
echo ""
echo "Примонтированные NTFS:"
mount | grep ntfs || echo "NTFS не примонтирован"
echo '```'

GMKTEC_DIAG

echo "  ✓ GMKtec диагностика завершена"

###############################################################################
# ЧАСТЬ 3: СВЯЗНОСТЬ
###############################################################################

echo ""
echo "╔══════════════════════════════════════╗"
echo "║   ЧАСТЬ 3: СВЯЗНОСТЬ                ║"
echo "╚══════════════════════════════════════╝"

{
echo ""
echo "## ЧАСТЬ 3: Связность Legion ↔ GMKtec"
echo ""

echo "### 3.1 SSH"
echo '```'
echo "SSH Legion → GMKtec:"
ssh -p "$GMKTEC_PORT" -o ConnectTimeout=5 "root@$GMKTEC_IP" "echo 'SSH OK'" 2>&1
echo ""
echo "Ping:"
ping -c 3 -W 2 "$GMKTEC_IP" 2>&1 | tail -3
echo '```'
echo ""

echo "### 3.2 Ollama (порт 11434)"
echo '```'
curl -s --max-time 5 "http://$GMKTEC_IP:11434/api/tags" 2>/dev/null | python3 -m json.tool 2>/dev/null | head -30 || echo "Ollama не доступен с Legion"
echo '```'
echo ""

echo "### 3.3 Внешний доступ"
echo '```'
echo "Внешний IP:"
curl -s --max-time 5 https://ifconfig.me 2>/dev/null || echo "Не определён"
echo ""
echo "Порт 2222 (SSH наружу):"
echo "Проверка через NAT: настроен на роутере Livebox 5"
echo '```'

} >> "$REPORT"

echo "  ✓ Связность проверена"

###############################################################################
# Копируем отчёт
###############################################################################

cp "$REPORT" ~/vibe-coding/docs/diagnostic-report.md
echo ""
echo "=========================================="
echo "  ОТЧЁТ СОХРАНЁН"
echo "=========================================="
echo "  ~/vibe-coding/docs/diagnostic-report.md"
echo ""
echo "  Для просмотра: cat ~/vibe-coding/docs/diagnostic-report.md"
echo "=========================================="
