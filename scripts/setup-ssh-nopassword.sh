#!/bin/bash
###############################################################################
# setup-ssh-nopassword.sh — Настройка SSH без пароля: Legion → GMKtec
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/setup-ssh-nopassword.sh
#
# После этого ВСЕ скрипты будут работать без ввода пароля.
###############################################################################

GMKTEC_IP="192.168.0.72"
GMKTEC_PORT="2222"

echo "=========================================="
echo "  НАСТРОЙКА SSH БЕЗ ПАРОЛЯ"
echo "  Legion → GMKtec"
echo "=========================================="
echo ""

# --- 1. Генерируем SSH ключ если нет ---
echo "[1/3] Проверяю SSH ключ..."
if [ -f ~/.ssh/id_ed25519.pub ]; then
    echo "  ✓ Ключ уже есть: ~/.ssh/id_ed25519"
else
    echo "  Создаю новый ключ..."
    ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "mmber@mark-legion"
    echo "  ✓ Ключ создан"
fi

echo ""
echo "[2/3] Копирую ключ на GMKtec..."
echo "  Введи пароль root GMKtec (mmber) — ПОСЛЕДНИЙ РАЗ!"
echo ""

ssh-copy-id -p "$GMKTEC_PORT" -i ~/.ssh/id_ed25519.pub "root@$GMKTEC_IP"

echo ""
echo "[3/3] Проверяю подключение без пароля..."

RESULT=$(ssh -p "$GMKTEC_PORT" -o BatchMode=yes -o ConnectTimeout=5 "root@$GMKTEC_IP" "echo OK" 2>/dev/null)

if [ "$RESULT" = "OK" ]; then
    echo "  ✓ SSH БЕЗ ПАРОЛЯ РАБОТАЕТ!"
    echo ""
    
    # Добавляем алиас для удобства
    if ! grep -q "alias gmk=" ~/.bashrc 2>/dev/null; then
        echo "" >> ~/.bashrc
        echo "# GMKtec SSH (без пароля)" >> ~/.bashrc
        echo "alias gmk='ssh -p $GMKTEC_PORT root@$GMKTEC_IP'" >> ~/.bashrc
        echo "  ✓ Алиас добавлен: gmk (набери 'gmk' чтобы зайти на GMKtec)"
    fi
    
    # Добавляем в SSH config
    if ! grep -q "Host gmktec" ~/.ssh/config 2>/dev/null; then
        cat >> ~/.ssh/config << EOF

Host gmktec
    HostName $GMKTEC_IP
    Port $GMKTEC_PORT
    User root
    IdentityFile ~/.ssh/id_ed25519
EOF
        chmod 600 ~/.ssh/config
        echo "  ✓ SSH config: теперь можно писать 'ssh gmktec'"
    fi
    
    echo ""
    echo "=========================================="
    echo "  ГОТОВО! Пароль больше не нужен."
    echo "=========================================="
    echo ""
    echo "  Теперь можно:"
    echo "    ssh gmktec          — зайти на GMKtec"
    echo "    gmk                 — то же самое (алиас)"
    echo "    scp -P 2222 ...     — копировать файлы"
    echo ""
    echo "  Все скрипты будут работать без пароля!"
    echo "=========================================="
else
    echo "  ✗ Не удалось! Проверь что пароль был введён правильно."
    echo "  Попробуй заново: bash scripts/setup-ssh-nopassword.sh"
fi
