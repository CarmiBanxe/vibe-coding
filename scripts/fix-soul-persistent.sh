#!/bin/bash
# fix-soul-persistent.sh — Деплой и защита SOUL.md от перезаписи OpenClaw
#
# Запускать на Legion: bash scripts/fix-soul-persistent.sh
#
# Защита работает двумя слоями:
#   1. ExecStartPost в openclaw-gateway-moa.service — восстанавливает SOUL.md через 3 сек после старта OpenClaw
#   2. chattr +i на workspace-файле — OpenClaw не может перезаписать
#   3. soul-guard.service — дополнительный юнит при каждом boot

set -e
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOUL_SOURCE="$REPO_DIR/docs/SOUL.md"
WORKSPACE_SOUL="/home/mmber/.openclaw/workspace-moa/SOUL.md"
PROTECTED_DIR="/root/.openclaw-moa/soul-protected"
PROTECTED_SOUL="$PROTECTED_DIR/SOUL.md"
SERVICE_OVERRIDE_DIR="/etc/systemd/system/openclaw-gateway-moa.service.d"
SERVICE_OVERRIDE="$SERVICE_OVERRIDE_DIR/soul-guard.conf"

echo "============================================"
echo "  SOUL.md Persistent Protection Deploy"
echo "============================================"
echo ""

# ─────────────────────────────────────────────────────────
# ШАГ 1: Проверка исходного файла
# ─────────────────────────────────────────────────────────
echo "[1/7] Проверка docs/SOUL.md..."
if [[ ! -f "$SOUL_SOURCE" ]]; then
    echo "  ОШИБКА: $SOUL_SOURCE не найден!"
    exit 1
fi
SOUL_BYTES=$(wc -c < "$SOUL_SOURCE")
echo "  $SOUL_SOURCE: $SOUL_BYTES байт ✓"

# ─────────────────────────────────────────────────────────
# ШАГ 2: Копируем SOUL.md в защищённое место на GMKtec
# ─────────────────────────────────────────────────────────
echo ""
echo "[2/7] Деплой SOUL.md на GMKtec (защищённая копия)..."
scp "$SOUL_SOURCE" gmktec:/tmp/soul_new.md
ssh gmktec "mkdir -p $PROTECTED_DIR && cp /tmp/soul_new.md $PROTECTED_SOUL && chmod 644 $PROTECTED_SOUL"
echo "  Защищённая копия: $PROTECTED_SOUL ✓"

# ─────────────────────────────────────────────────────────
# ШАГ 3: Деплой в workspace (снимаем immutable если есть)
# ─────────────────────────────────────────────────────────
echo ""
echo "[3/7] Деплой в workspace-moa..."
ssh gmktec "sudo chattr -i $WORKSPACE_SOUL 2>/dev/null || true && cp $PROTECTED_SOUL $WORKSPACE_SOUL && chmod 644 $WORKSPACE_SOUL"
echo "  $WORKSPACE_SOUL обновлён ✓"

# ─────────────────────────────────────────────────────────
# ШАГ 4: chattr +i — делаем immutable
# ─────────────────────────────────────────────────────────
echo ""
echo "[4/7] Защита chattr +i..."
CHATTR_RESULT=$(ssh gmktec "sudo chattr +i $WORKSPACE_SOUL 2>&1 && echo OK || echo FAIL")
if echo "$CHATTR_RESULT" | grep -q "OK"; then
    echo "  chattr +i: активирован ✓"
else
    echo "  chattr +i: не поддерживается ФС (${CHATTR_RESULT}) — продолжаем без него"
fi

# ─────────────────────────────────────────────────────────
# ШАГ 5: ExecStartPost override для openclaw-gateway-moa.service
# (PRIMARY PROTECTION — запускается через 3 сек после старта OpenClaw)
# ─────────────────────────────────────────────────────────
echo ""
echo "[5/7] Создание ExecStartPost override..."

# Пишем conf-файл через heredoc в файл (допустимо по правилам)
cat << 'CONF_EOF' | ssh gmktec "sudo mkdir -p $SERVICE_OVERRIDE_DIR && sudo tee $SERVICE_OVERRIDE > /dev/null"
[Service]
ExecStartPost=/bin/bash -c 'sleep 3 && chattr -i /home/mmber/.openclaw/workspace-moa/SOUL.md 2>/dev/null; cp /root/.openclaw-moa/soul-protected/SOUL.md /home/mmber/.openclaw/workspace-moa/SOUL.md && chattr +i /home/mmber/.openclaw/workspace-moa/SOUL.md 2>/dev/null || true'
CONF_EOF

echo "  ExecStartPost: $SERVICE_OVERRIDE ✓"

# ─────────────────────────────────────────────────────────
# ШАГ 6: soul-guard.service (BACKUP — активируется при boot)
# ─────────────────────────────────────────────────────────
echo ""
echo "[6/7] Создание soul-guard.service (boot backup)..."

cat << 'UNIT_EOF' | ssh gmktec "sudo tee /etc/systemd/system/openclaw-soul-guard.service > /dev/null"
[Unit]
Description=Banxe SOUL.md Guard — restore compliance rules after OpenClaw restart
After=openclaw-gateway-moa.service
Requires=openclaw-gateway-moa.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'sleep 3 && chattr -i /home/mmber/.openclaw/workspace-moa/SOUL.md 2>/dev/null; cp /root/.openclaw-moa/soul-protected/SOUL.md /home/mmber/.openclaw/workspace-moa/SOUL.md && chattr +i /home/mmber/.openclaw/workspace-moa/SOUL.md 2>/dev/null || true && echo "SOUL.md restored"'
ExecReload=/bin/bash -c 'chattr -i /home/mmber/.openclaw/workspace-moa/SOUL.md 2>/dev/null; cp /root/.openclaw-moa/soul-protected/SOUL.md /home/mmber/.openclaw/workspace-moa/SOUL.md && chattr +i /home/mmber/.openclaw/workspace-moa/SOUL.md 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
UNIT_EOF

ssh gmktec "sudo systemctl daemon-reload && sudo systemctl enable openclaw-soul-guard.service"
echo "  openclaw-soul-guard.service: включён ✓"

# ─────────────────────────────────────────────────────────
# ШАГ 7: Перезапуск OpenClaw и верификация
# ─────────────────────────────────────────────────────────
echo ""
echo "[7/7] Перезапуск OpenClaw и проверка..."
ssh gmktec "sudo systemctl restart openclaw-gateway-moa.service"
echo "  Ожидаем 8 секунд (3 сек ExecStartPost + буфер)..."
sleep 8

BOT_STATUS=$(ssh gmktec "sudo systemctl is-active openclaw-gateway-moa.service")
SOUL_CHECK=$(ssh gmktec "head -3 $WORKSPACE_SOUL")
SOUL_ATTR=$(ssh gmktec "sudo lsattr $WORKSPACE_SOUL 2>/dev/null | awk '{print \$1}' || echo unknown")

echo ""
echo "  Бот: $BOT_STATUS"
echo "  SOUL.md первые строки:"
echo "    $SOUL_CHECK"
echo "  Атрибуты: $SOUL_ATTR"

# Проверяем что SOUL.md содержит compliance-контент
if ssh gmktec "grep -q 'REJECT' $WORKSPACE_SOUL"; then
    echo ""
    echo "  SOUL.md: содержит compliance-правила ✓"
else
    echo ""
    echo "  ПРЕДУПРЕЖДЕНИЕ: SOUL.md не содержит 'REJECT' — проверь вручную!"
fi

# ─────────────────────────────────────────────────────────
# Коммит
# ─────────────────────────────────────────────────────────
echo ""
echo "Коммит docs/SOUL.md и скрипта..."
cd "$REPO_DIR"
git add docs/SOUL.md scripts/fix-soul-persistent.sh
git commit -m "feat: persistent SOUL.md protection (chattr+i + ExecStartPost + soul-guard.service)

- docs/SOUL.md: source of truth for compliance rules (Syria moved to EDD/HOLD)
- Protected copy on GMKtec: /root/.openclaw-moa/soul-protected/SOUL.md
- ExecStartPost override: restores SOUL.md 3s after every OpenClaw restart
- chattr +i: workspace SOUL.md immutable (OpenClaw cannot overwrite)
- openclaw-soul-guard.service: boot-time backup guard"
git push origin main

echo ""
echo "============================================"
echo "  ГОТОВО"
echo "============================================"
echo ""
echo "  Защита активирована:"
echo "  1. chattr +i на $WORKSPACE_SOUL"
echo "  2. ExecStartPost в openclaw-gateway-moa.service (3 сек задержка)"
echo "  3. openclaw-soul-guard.service (boot-time)"
echo ""
echo "  Для обновления SOUL.md:"
echo "  1. Редактируй docs/SOUL.md"
echo "  2. Запускай: bash scripts/fix-soul-persistent.sh"
echo ""
