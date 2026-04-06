#!/bin/bash
###############################################################################
# post-migration-sync.sh — Синхронизация workspace после миграции + MEMORY.md
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/post-migration-sync.sh
#
# Проблема: upgrade-bot-prompts-v2 записал файлы в /home/mmber/.openclaw/workspace
#   а миграция скопировала СТАРЫЕ версии в /opt/openclaw/workspace-moa
#   Нужно скопировать НОВЫЕ промпты в workspace бота
#
# Также обновляет MEMORY.md с информацией о миграции
###############################################################################

echo "=========================================="
echo "  ПОСТ-МИГРАЦИЯ: синхронизация + MEMORY.md"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE'
export PATH="$PATH:/root/.local/bin:/usr/local/bin"

echo ""
echo "[1/3] Копирую обновлённые промпты в workspace бота..."

SRC="/home/mmber/.openclaw/workspace"
DST="/opt/openclaw/workspace-moa"

for f in SOUL.md BOOTSTRAP.md USER.md IDENTITY.md; do
    if [ -f "$SRC/$f" ]; then
        SRC_TIME=$(stat -c %Y "$SRC/$f" 2>/dev/null || echo 0)
        DST_TIME=$(stat -c %Y "$DST/$f" 2>/dev/null || echo 0)
        
        if [ "$SRC_TIME" -gt "$DST_TIME" ]; then
            cp "$SRC/$f" "$DST/$f"
            chown openclaw:openclaw "$DST/$f"
            echo "  ✓ $f обновлён (новая версия)"
        else
            echo "  · $f актуален"
        fi
    fi
done

# Также копируем AGENTS.md, TOOLS.md, HEARTBEAT.md если новее
for f in AGENTS.md TOOLS.md HEARTBEAT.md; do
    if [ -f "$SRC/$f" ]; then
        cp "$SRC/$f" "$DST/$f" 2>/dev/null
        chown openclaw:openclaw "$DST/$f" 2>/dev/null
    fi
done

echo ""
echo "  Текущие файлы в $DST:"
ls -la "$DST"/*.md 2>/dev/null | grep -v ".bak" | sed 's/^/    /'

echo ""
echo "[2/3] Обновляю MEMORY.md..."

# Обновляем секцию о миграции в docs/MEMORY.md (который синхронизируется через GitHub)
MEMORY_GH="/data/vibe-coding/docs/MEMORY.md"

if [ -f "$MEMORY_GH" ]; then
    # Проверяем есть ли уже секция миграции
    if ! grep -q "Миграция root → openclaw" "$MEMORY_GH" 2>/dev/null; then
        chattr -i "$MEMORY_GH" 2>/dev/null
        
        # Добавляем информацию о миграции перед разделом ---
        python3 << 'PYUPDATE'
import re
from datetime import datetime

memory_path = "/data/vibe-coding/docs/MEMORY.md"

with open(memory_path) as f:
    content = f.read()

# Обновляем дату
now = datetime.now().strftime("%d.%m.%Y %H:%M CET")
content = re.sub(
    r'> Последнее обновление:.*',
    f'> Последнее обновление: {now}',
    content
)
content = re.sub(
    r'> Обновлено после:.*',
    f'> Обновлено после: Миграция root→openclaw + system prompts v2',
    content
)

# Добавляем секцию миграции
migration_section = """
### Миграция root → openclaw (30.03.2026)
- Gateway теперь запускается от пользователя **openclaw** (не root)
- Systemd сервис: `openclaw-gateway-moa.service` (User=openclaw)
- Home: `/opt/openclaw`
- Workspace: `/opt/openclaw/workspace-moa`
- Конфиг: `/opt/openclaw/.openclaw/openclaw.json`
- Autosync копирует MEMORY.md + SYSTEM-STATE.md в оба workspace

### System Prompts v2 (30.03.2026)
- Промпты через нативные .md файлы (не JSON!)
- SOUL.md — идентичность CTIO, правила, безопасность
- BOOTSTRAP.md — 4 режима: обычный, стратегический, исследование, ревью
- USER.md — информация о CEO и CTIO
- IDENTITY.md — краткая карточка бота
- OpenClaw загружает 9 .md файлов при каждом ходе автоматически (стр. 94-96)
- НЕ трогать agents.main в openclaw.json! (вызывает Config invalid)
"""

# Вставляем после "ТЕКУЩЕЕ СОСТОЯНИЕ ИНФРАСТРУКТУРЫ"
if "### GMKtec EVO-X2" in content:
    # Вставляем перед GMKtec секцией
    content = content.replace(
        "### GMKtec EVO-X2",
        migration_section + "\n### GMKtec EVO-X2"
    )
elif "---" in content:
    # Вставляем перед первым ---
    first_hr = content.index("---")
    content = content[:first_hr] + migration_section + "\n" + content[first_hr:]

with open(memory_path, 'w') as f:
    f.write(content)

print("  ✓ MEMORY.md обновлён")
PYUPDATE
        
        chattr +i "$MEMORY_GH" 2>/dev/null
    else
        echo "  · Секция миграции уже есть в MEMORY.md"
    fi
else
    echo "  ⚠ MEMORY.md не найден: $MEMORY_GH"
fi

echo ""
echo "[3/3] Пушу MEMORY.md в GitHub..."

cd /data/vibe-coding
git add docs/MEMORY.md 2>/dev/null
git commit -m "memory: миграция root→openclaw + system prompts v2 [auto]" 2>/dev/null
git push origin main 2>/dev/null && echo "  ✓ Запушено в GitHub" || echo "  ⚠ Push не удался (не критично, cron синхронизирует)"

echo ""
echo "  Проверка gateway:"
if ss -tlnp | grep -q ":18789 "; then
    echo "  ✓ Gateway жив (порт 18789)"
    ps aux | grep -E "[o]penclaw.*gate" | awk '{print "    User: "$1", PID: "$2}' | head -1
else
    echo "  ✗ Gateway не работает!"
fi

REMOTE

echo ""
echo "=========================================="
echo "  ГОТОВО"
echo "=========================================="
echo ""
echo "  Проверь бота — напиши ему:"
echo "    1. «Кто ты?» — должен представиться как CTIO"  
echo "    2. «стратегия выхода на UK рынок» — стратегический режим"
echo "=========================================="
