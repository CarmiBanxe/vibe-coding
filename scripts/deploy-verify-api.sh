#!/bin/bash
# deploy-verify-api.sh — Деплой Verification API на GMKtec (порт 8094)
#
# Запускать с Legion: cd ~/vibe-coding && bash scripts/deploy-verify-api.sh
#
# Что делает:
#   1. Копирует src/compliance/ на GMKtec → /data/banxe/compliance/
#   2. Создаёт systemd service banxe-verify-api.service
#   3. Запускает сервис, проверяет /health
#   4. Обновляет SOUL.md compliance и kyc агентов (добавляет инструкцию verify)
#   5. Перезапускает OpenClaw gateway

set -e

GMKTEC="gmktec"
REMOTE_COMPLIANCE="/data/banxe/compliance"
REMOTE_VIBE="/data/vibe-coding"

echo "[1/5] Синхронизация src/compliance/ → GMKtec..."
rsync -av --delete \
    ~/vibe-coding/src/compliance/ \
    ${GMKTEC}:${REMOTE_COMPLIANCE}/

echo "[2/5] Создание systemd service banxe-verify-api..."
ssh $GMKTEC "cat > /etc/systemd/system/banxe-verify-api.service << 'EOF'
[Unit]
Description=BANXE Verification API (port 8094)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/data/banxe/compliance
Environment=PYTHONPATH=/data/banxe/compliance
ExecStart=/usr/bin/python3 /data/banxe/compliance/verify_api.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable banxe-verify-api
systemctl restart banxe-verify-api
sleep 2
systemctl status banxe-verify-api --no-pager | head -15
"

echo "[3/5] Health check..."
ssh $GMKTEC "curl -s http://127.0.0.1:8094/health"

echo ""
echo "[4/5] Обновление SOUL.md агентов compliance + kyc..."

# Инструкция верификации для добавления в SOUL.md агентов
VERIFY_BLOCK=$(cat << 'VERIFY_EOF'

---
## VERIFY BEFORE SEND (обязательно)

Перед отправкой любого compliance-вердикта:
1. Сформулируй ответ
2. Проверь через API: curl -s "http://127.0.0.1:8094/verify?statement=<твой_ответ>&agent_role=<твоя_роль>"
3. Если consensus=REFUTED — НЕ отправляй. Перефразируй в соответствии с reason.
4. Если consensus=UNCERTAIN — добавь оговорку или запроси HITL.
5. Если hitl_required=true — всегда эскалируй на человека.

Пример вызова:
  curl -s "http://127.0.0.1:8094/verify?statement=Approve+PEP+without+EDD&agent_role=Compliance+Officer"
  → {"consensus":"REFUTED","hitl_required":true,"reason":"without EDD pattern"}
VERIFY_EOF
)

# Добавляем блок в compliance SOUL.md если его ещё нет
ssh $GMKTEC "
COMPLIANCE_SOUL='/home/mmber/.openclaw/workspace-moa-compliance/SOUL.md'
KYC_SOUL='/home/mmber/.openclaw/workspace-moa-kyc/SOUL.md'

for SOUL_FILE in \"\$COMPLIANCE_SOUL\" \"\$KYC_SOUL\"; do
    if [ -f \"\$SOUL_FILE\" ]; then
        if grep -q 'VERIFY BEFORE SEND' \"\$SOUL_FILE\"; then
            echo \"  SKIP: \$SOUL_FILE — verify block already present\"
        else
            # Снять иммутабельность если есть
            chattr -i \"\$SOUL_FILE\" 2>/dev/null || true
            cat >> \"\$SOUL_FILE\" << 'APPENDEOF'

---
## VERIFY BEFORE SEND (обязательно)

Перед отправкой любого compliance-вердикта:
1. Сформулируй ответ
2. Проверь через API: curl -s \"http://127.0.0.1:8094/verify?statement=<твой_ответ>&agent_role=<твоя_роль>\"
3. Если consensus=REFUTED — НЕ отправляй. Перефразируй в соответствии с reason.
4. Если consensus=UNCERTAIN — добавь оговорку или запроси HITL.
5. Если hitl_required=true — всегда эскалируй на человека.

Пример вызова:
  curl -s \"http://127.0.0.1:8094/verify?statement=Approve+PEP+without+EDD&agent_role=Compliance+Officer\"
  → {\"consensus\":\"REFUTED\",\"hitl_required\":true,\"reason\":\"without EDD pattern\"}
APPENDEOF
            # Вернуть иммутабельность
            chattr +i \"\$SOUL_FILE\" 2>/dev/null || true
            echo \"  UPDATED: \$SOUL_FILE\"
        fi
    else
        echo \"  NOT FOUND: \$SOUL_FILE\"
    fi
done
"

echo "[5/5] Перезапуск OpenClaw gateway..."
ssh $GMKTEC "systemctl restart openclaw-moa 2>/dev/null || systemctl restart openclaw 2>/dev/null || echo '  OpenClaw перезапуск — сделай вручную если нужно'"

echo ""
echo "=== ГОТОВО ==="
echo "  Verification API: http://gmktec:8094/verify"
echo "  Health:           http://gmktec:8094/health"
echo "  Тест:"
echo "    ssh gmktec 'curl -s \"http://127.0.0.1:8094/verify?statement=Approve+PEP+without+EDD&agent_role=Compliance+Officer\"'"
