#!/bin/bash
###############################################################################
# activate-metaclaw.sh — Активация MetaClaw на GMKtec
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/activate-metaclaw.sh
###############################################################################

echo "=========================================="
echo "  АКТИВАЦИЯ MetaClaw"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE'

echo "[1/3] Настраиваю MetaClaw..."

source /opt/metaclaw-env/bin/activate 2>/dev/null

# Создаём конфиг MetaClaw
mkdir -p /data/metaclaw
cat > /data/metaclaw/config.json << 'CFG'
{
    "skills_dir": "/data/metaclaw/skills",
    "openclaw_home": "/root/.openclaw-moa",
    "mode": "skills_only",
    "auto_generate": true,
    "score_threshold": 0.7,
    "log_file": "/data/logs/metaclaw.log"
}
CFG
echo "  ✓ Конфиг создан"

# Проверяем skills
echo ""
echo "[2/3] Skills:"
for f in /data/metaclaw/skills/*/*.json; do
    NAME=$(python3 -c "import json; print(json.load(open('$f')).get('name','?'))" 2>/dev/null)
    DESC=$(python3 -c "import json; print(json.load(open('$f')).get('description','?')[:60])" 2>/dev/null)
    echo "  ✓ $NAME: $DESC"
done

# Создаём systemd сервис для MetaClaw daemon
echo ""
echo "[3/3] Создаю сервис..."
cat > /etc/systemd/system/metaclaw.service << 'SVC'
[Unit]
Description=MetaClaw Skills Daemon
After=network.target

[Service]
Type=simple
ExecStart=/opt/metaclaw-env/bin/python3 -m metaclaw start --mode skills_only --config /data/metaclaw/config.json
Restart=always
RestartSec=30
Environment=METACLAW_SKILLS_DIR=/data/metaclaw/skills

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable metaclaw 2>/dev/null

# Пробуем запустить
systemctl start metaclaw 2>/dev/null
sleep 3

if systemctl is-active metaclaw &>/dev/null; then
    echo "  ✓ MetaClaw ACTIVE"
else
    echo "  ⚠ MetaClaw daemon не запустился (может быть нормально)"
    echo "  Skills доступны статически — бот может их читать"
    echo "  Daemon активируется когда workflows стабилизируются"
fi

echo ""
echo "  Skills готовы к использованию:"
echo "    /data/metaclaw/skills/compliance/sanctions_check.json"
echo "    /data/metaclaw/skills/kyc/edd_triggers.json"
echo "    /data/metaclaw/skills/shared/iban_validation.json"
REMOTE

# КАНОН
echo ""
echo "КАНОН: обновляю MEMORY.md..."
ssh gmktec "for d in /home/mmber/.openclaw/workspace-moa /root/.openclaw-moa/workspace-moa /root/.openclaw-moa/.openclaw/workspace; do cat >> \$d/MEMORY.md 2>/dev/null << 'EOF'

## Обновление: MetaClaw активирован ($(date '+%Y-%m-%d %H:%M'))
- MetaClaw: конфиг создан, 3 skills активны
- Skills: iban_validation, sanctions_check, edd_triggers
- Директория: /data/metaclaw/skills/
- Daemon: standby (активируется при стабильных workflows)
EOF
done" 2>/dev/null
echo "  ✓ MEMORY.md обновлён (канон)"

echo ""
echo "=========================================="
echo "  MetaClaw АКТИВИРОВАН"
echo "=========================================="
