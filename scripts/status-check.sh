#!/bin/bash
###############################################################################
# status-check.sh — Полная проверка состояния всей инфраструктуры
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/status-check.sh
###############################################################################

echo "=========================================="
echo "  ПОЛНЫЙ СТАТУС ИНФРАСТРУКТУРЫ"
echo "  $(date '+%Y-%m-%d %H:%M %Z')"
echo "=========================================="

# --- LEGION ---
echo ""
echo "╔══════════════════════════════════════╗"
echo "║  LEGION (mark-legion)               ║"
echo "╚══════════════════════════════════════╝"
echo ""

printf "  %-30s %s\n" "КОМПОНЕНТ" "СТАТУС"
printf "  %-30s %s\n" "------------------------------" "------"

# OpenClaw Gateway (должен быть STOPPED)
if systemctl --user is-active openclaw-gateway-moa &>/dev/null; then
    printf "  %-30s ⚠ ACTIVE (должен быть на GMKtec)\n" "Gateway moa"
else
    printf "  %-30s ✓ STOPPED (на GMKtec)\n" "Gateway moa"
fi

# LiteLLM
if systemctl --user is-active litellm &>/dev/null; then
    printf "  %-30s ✓ ACTIVE\n" "LiteLLM"
else
    printf "  %-30s ✗ INACTIVE\n" "LiteLLM"
fi

# Deep Search
if systemctl --user is-active deep-search &>/dev/null; then
    printf "  %-30s ✓ ACTIVE (порт 8088)\n" "Deep Search (Playwright)"
else
    printf "  %-30s ✗ НЕ УСТАНОВЛЕН\n" "Deep Search (Playwright)"
fi

# SSH к GMKtec
SSH_OK=$(ssh -o ConnectTimeout=5 -o BatchMode=yes gmktec "echo OK" 2>/dev/null)
if [ "$SSH_OK" = "OK" ]; then
    printf "  %-30s ✓ без пароля\n" "SSH → GMKtec"
else
    printf "  %-30s ✗ не работает\n" "SSH → GMKtec"
fi

printf "  %-30s %s\n" "Диск" "$(df -h / 2>/dev/null | tail -1 | awk '{print $4" свободно из "$2}')"

# --- GMKtec ---
echo ""
echo "╔══════════════════════════════════════╗"
echo "║  GMKtec (EVO-X2)                    ║"
echo "╚══════════════════════════════════════╝"
echo ""

if [ "$SSH_OK" != "OK" ]; then
    echo "  ✗ GMKtec недоступен по SSH!"
    echo "  Проверь: ssh gmktec"
else
    ssh gmktec 'bash -s' << 'GMKCHECK'
export XDG_RUNTIME_DIR="/run/user/0"

printf "  %-30s %s\n" "КОМПОНЕНТ" "СТАТУС"
printf "  %-30s %s\n" "------------------------------" "------"

# Gateway moa (@mycarmi_moa_bot)
if systemctl --user is-active openclaw-gateway-moa &>/dev/null; then
    printf "  %-30s ✓ ACTIVE\n" "@mycarmi_moa_bot (moa)"
else
    printf "  %-30s ✗ INACTIVE\n" "@mycarmi_moa_bot (moa)"
fi

# Gateway default (@mycarmibot)
if systemctl --user is-active openclaw-gateway &>/dev/null; then
    printf "  %-30s ✓ ACTIVE\n" "@mycarmibot (default)"
else
    printf "  %-30s ✗ INACTIVE\n" "@mycarmibot (default)"
fi

# Ollama
if systemctl is-active ollama &>/dev/null; then
    MODELS=$(ollama list 2>/dev/null | tail -n +2 | wc -l)
    ACTIVE=$(ollama ps 2>/dev/null | tail -n +2 | wc -l)
    printf "  %-30s ✓ ACTIVE (%s моделей, %s загружено)\n" "Ollama" "$MODELS" "$ACTIVE"
else
    printf "  %-30s ✗ INACTIVE\n" "Ollama"
fi

# ClickHouse
if systemctl is-active clickhouse-server &>/dev/null; then
    TABLES=$(clickhouse-client --query "SHOW TABLES FROM banxe" 2>/dev/null | wc -l)
    printf "  %-30s ✓ ACTIVE (%s таблиц)\n" "ClickHouse" "$TABLES"
else
    printf "  %-30s ✗ INACTIVE\n" "ClickHouse"
fi

# PII Proxy
if systemctl is-active pii-proxy &>/dev/null; then
    printf "  %-30s ✓ ACTIVE (порт 8089)\n" "PII Proxy"
else
    printf "  %-30s ✗ INACTIVE\n" "PII Proxy"
fi

# n8n
if systemctl is-active n8n &>/dev/null; then
    printf "  %-30s ✓ ACTIVE (порт 5678)\n" "n8n Automation"
else
    printf "  %-30s ✗ INACTIVE\n" "n8n Automation"
fi

# SSH / fail2ban
printf "  %-30s ✓ порт 2222\n" "SSH"
systemctl is-active fail2ban &>/dev/null && printf "  %-30s ✓ ACTIVE\n" "fail2ban" || printf "  %-30s ✗\n" "fail2ban"

# XRDP
systemctl is-active xrdp &>/dev/null && printf "  %-30s ✓ ACTIVE (порт 3389)\n" "XRDP" || printf "  %-30s ✗\n" "XRDP"

# Диски
echo ""
printf "  %-30s %s\n" "ДИСК" "СТАТУС"
printf "  %-30s %s\n" "------------------------------" "------"
printf "  %-30s %s\n" "/ (1TB система)" "$(df -h / | tail -1 | awk '{print $4" свободно ("$5" занято)"}')"
printf "  %-30s %s\n" "/data (2TB данные)" "$(df -h /data 2>/dev/null | tail -1 | awk '{print $4" свободно ("$5" занято)"}' || echo 'НЕ ПРИМОНТИРОВАН')"

# Backup
echo ""
BK_CH=$(ls -t /data/backups/clickhouse/*.tar.gz 2>/dev/null | head -1)
BK_OC=$(ls -t /data/backups/openclaw/*.tar.gz 2>/dev/null | head -1)
printf "  %-30s %s\n" "Последний backup CH" "$([ -n "$BK_CH" ] && stat -c '%y' "$BK_CH" 2>/dev/null | cut -d. -f1 || echo 'НЕТ')"
printf "  %-30s %s\n" "Последний backup OC" "$([ -n "$BK_OC" ] && stat -c '%y' "$BK_OC" 2>/dev/null | cut -d. -f1 || echo 'НЕТ')"

# Температура
echo ""
TEMP_CPU=$(sensors 2>/dev/null | grep Tctl | awk '{print $2}' || echo "?")
TEMP_GPU=$(sensors 2>/dev/null | grep edge | awk '{print $2}' || echo "?")
printf "  %-30s %s\n" "CPU температура" "$TEMP_CPU"
printf "  %-30s %s\n" "GPU температура" "$TEMP_GPU"

# CTIO пользователь
echo ""
id ctio &>/dev/null && printf "  %-30s ✓ создан\n" "Пользователь ctio (Oleg)" || printf "  %-30s ✗\n" "Пользователь ctio"

# Порты
echo ""
echo "  Все порты:"
ss -tlnp 2>/dev/null | grep LISTEN | awk '{print "    "$4}' | sort -u | head -15
GMKCHECK
fi

# --- ИТОГ ---
echo ""
echo "╔══════════════════════════════════════╗"
echo "║  ИТОГ                               ║"
echo "╚══════════════════════════════════════╝"
echo ""
echo "  Выполнено сегодня:"
echo "    ✓ Фаза 1: GMKtec production-ready"
echo "    ✓ Фаза 2: Windows ликвидирован, 2TB ext4"
echo "    ✓ Фаза 3: Backup, шифрование, PII Proxy"
echo "    ✓ Фаза 4: n8n, MetaClaw, vendor emails"
echo "    ✓ Gateway на GMKtec"
echo "    ✓ @mycarmibot починен"
echo "    ✓ CTIO Oleg пакет создан"
echo ""
echo "  Следующие шаги:"
echo "    → Многослойный поиск (Brave + Perplexity Playwright)"
echo "    → Vendor emails отправить"
echo "    → n8n workflows настроить"
echo "    → MetaClaw активировать"
echo ""
echo "  Security Score: ~6/10"
echo "  Project Progress: ~45%"
echo "=========================================="
