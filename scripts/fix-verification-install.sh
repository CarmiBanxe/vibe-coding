#!/bin/bash
###############################################################################
# fix-verification-install.sh — Починка установки Semgrep и pre-commit
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/fix-verification-install.sh
#
# Проблема: Ubuntu 24.04 блокирует pip install без venv (PEP 668)
# Решение: pipx для CLI-инструментов + --break-system-packages как fallback
#
# CodeRabbit CLI не существует как npm-пакет — работает через GitHub App
###############################################################################

echo "=========================================="
echo "  ПОЧИНКА: Semgrep + pre-commit"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE_END'

LOG="/data/logs/verification-fix.log"
log() { echo "$(date '+%H:%M:%S') $1" | tee -a "$LOG"; }

###########################################################################
# 1. Semgrep — через pipx или venv
###########################################################################
log "[1/4] Устанавливаю Semgrep..."

if command -v semgrep &>/dev/null; then
    log "  ✓ Semgrep уже есть: $(semgrep --version 2>/dev/null)"
else
    # Способ 1: pipx
    if command -v pipx &>/dev/null; then
        log "  Через pipx..."
        pipx install semgrep 2>&1 | tail -3
    else
        # Устанавливаем pipx
        log "  Устанавливаю pipx..."
        apt-get install -y pipx 2>/dev/null || pip3 install --break-system-packages pipx 2>/dev/null
        pipx ensurepath 2>/dev/null
        export PATH="$PATH:/root/.local/bin"
        
        log "  Устанавливаю Semgrep через pipx..."
        pipx install semgrep 2>&1 | tail -5
    fi
    
    # Обновляем PATH
    export PATH="$PATH:/root/.local/bin"
    
    if command -v semgrep &>/dev/null; then
        log "  ✓ Semgrep $(semgrep --version 2>/dev/null) установлен (pipx)"
    else
        # Fallback: --break-system-packages
        log "  pipx не сработал, пробую --break-system-packages..."
        pip3 install --break-system-packages semgrep 2>&1 | tail -3
        
        if command -v semgrep &>/dev/null; then
            log "  ✓ Semgrep $(semgrep --version 2>/dev/null) установлен (pip3)"
        else
            log "  ✗ Semgrep не удалось установить"
        fi
    fi
fi

###########################################################################
# 2. pre-commit
###########################################################################
log "[2/4] Устанавливаю pre-commit..."

if command -v pre-commit &>/dev/null; then
    log "  ✓ pre-commit уже есть: $(pre-commit --version 2>/dev/null)"
else
    # Через pipx
    export PATH="$PATH:/root/.local/bin"
    
    if command -v pipx &>/dev/null; then
        pipx install pre-commit 2>&1 | tail -3
    else
        pip3 install --break-system-packages pre-commit 2>&1 | tail -3
    fi
    
    export PATH="$PATH:/root/.local/bin"
    
    if command -v pre-commit &>/dev/null; then
        log "  ✓ pre-commit $(pre-commit --version 2>/dev/null) установлен"
    else
        log "  ✗ pre-commit не установился"
    fi
fi

###########################################################################
# 3. Pre-commit hooks в репо
###########################################################################
log "[3/4] Настраиваю pre-commit hooks..."

REPO="/data/vibe-coding"
cd "$REPO"

export PATH="$PATH:/root/.local/bin"

# Устанавливаем hooks
if command -v pre-commit &>/dev/null; then
    pre-commit install 2>&1 || log "  ⚠ pre-commit install не удался"
    log "  ✓ Pre-commit hooks установлены"
else
    log "  ⚠ pre-commit не найден — hooks не установлены"
fi

###########################################################################
# 4. Тест Semgrep
###########################################################################
log "[4/4] Тестирую..."

export PATH="$PATH:/root/.local/bin"

echo ""
echo "  Инструменты:"
for TOOL in semgrep snyk pre-commit; do
    if command -v "$TOOL" &>/dev/null; then
        VER=$($TOOL --version 2>/dev/null | head -1)
        echo "    ✓ $TOOL — $VER"
    else
        echo "    ✗ $TOOL — НЕ УСТАНОВЛЕН"
    fi
done

echo ""
echo "  Тест Semgrep:"
if command -v semgrep &>/dev/null; then
    # Тест на тестовом файле
    cat > /tmp/test-vuln.py << 'TESTPY'
password = "super_secret_123"
result = eval(user_input)
amount = float("100.50")
TESTPY
    
    RESULTS=$(semgrep --config "$REPO/.semgrep/banxe-rules.yml" /tmp/test-vuln.py --json 2>/dev/null | \
        python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    results=d.get('results',[])
    print(f'    Найдено {len(results)} уязвимостей в тестовом файле:')
    for r in results:
        cid=r.get('check_id','?').split('.')[-1]
        print(f'      - {cid}')
except Exception as e:
    print(f'    Ошибка: {e}')
" 2>/dev/null)
    echo "$RESULTS"
    rm -f /tmp/test-vuln.py
    
    # Сканируем реальные скрипты
    echo ""
    echo "  Сканирование scripts/:"
    SCAN=$(semgrep --config "$REPO/.semgrep/banxe-rules.yml" "$REPO/scripts/" --json 2>/dev/null | \
        python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    results=d.get('results',[])
    print(f'    Найдено {len(results)} потенциальных проблем')
    for r in results[:5]:
        f=r.get('path','?').split('/')[-1]
        cid=r.get('check_id','?').split('.')[-1]
        line=r.get('start',{}).get('line','?')
        print(f'      - {f}:{line} → {cid}')
    if len(results) > 5:
        print(f'      ... и ещё {len(results)-5}')
except Exception as e:
    print(f'    Ошибка: {e}')
" 2>/dev/null)
    echo "$SCAN"
else
    echo "    Semgrep не установлен — тест пропущен"
fi

# Обновляем снапшот инструментов
cat > /data/logs/verification-tools-snapshot.txt << SNAP
# Verification tools snapshot — $(date '+%Y-%m-%d %H:%M')
semgrep=$(command -v semgrep 2>/dev/null || echo "NOT_INSTALLED")
snyk=$(command -v snyk 2>/dev/null || echo "NOT_INSTALLED")
pre-commit=$(command -v pre-commit 2>/dev/null || echo "NOT_INSTALLED")
coderabbit=GITHUB_APP_ONLY
SNAP

# Добавляем PATH в .bashrc чтобы cron и ssh видели pipx
if ! grep -q "/.local/bin" /root/.bashrc 2>/dev/null; then
    echo 'export PATH="$PATH:/root/.local/bin"' >> /root/.bashrc
    log "  ✓ PATH обновлён в .bashrc"
fi

# Обновляем ctio-watcher чтобы он тоже видел pipx PATH
if ! grep -q "/.local/bin" /data/vibe-coding/ctio-watcher.sh 2>/dev/null; then
    sed -i '2a export PATH="$PATH:/root/.local/bin"' /data/vibe-coding/ctio-watcher.sh
    log "  ✓ PATH добавлен в ctio-watcher.sh"
fi
if ! grep -q "/.local/bin" /data/vibe-coding/check-tools-integrity.sh 2>/dev/null; then
    sed -i '2a export PATH="$PATH:/root/.local/bin"' /data/vibe-coding/check-tools-integrity.sh 2>/dev/null
    log "  ✓ PATH добавлен в check-tools-integrity.sh"
fi

REMOTE_END

echo ""
echo "=========================================="
echo "  РЕЗУЛЬТАТ"
echo "=========================================="
echo ""
echo "  О CodeRabbit:"
echo "    CLI-пакета в npm не существует."
echo "    CodeRabbit работает как GitHub App:"
echo "    → github.com/apps/coderabbit → Install"
echo "    → Выбрать репо CarmiBanxe/vibe-coding"
echo "    → Автоматически ревьюит каждый PR"
echo ""
echo "  Все остальные инструменты работают локально на GMKtec."
