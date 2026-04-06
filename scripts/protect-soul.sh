#!/bin/bash
###############################################################################
# protect-soul.sh — защита SOUL.md от перезаписи OpenClaw при рестарте
#
# Проблема: при рестарте OpenClaw reinitializes workspace и перезаписывает
#           SOUL.md своим шаблоном по умолчанию.
#
# Решение:
#   1. soul-protected/ = канонический источник истины
#   2. chattr +i = иммутабельность SOUL.md в обоих workspace
#   3. memory-autosync-watcher.sh = мониторинг + авторестор при сбое
#
# G-05 Governance Gate (CLASS_B):
#   update требует явного approver — CLASS_B изменение (самоперезапись).
#   Без approver скрипт НЕ деплоит изменения в workspaces.
#
# Использование:
#   Первый деплой:  bash scripts/protect-soul.sh deploy
#   Обновить:       bash scripts/protect-soul.sh update "/путь/к/новому/SOUL.md" \
#                       --approver mark-001 --role DEVELOPER --reason "quarterly update"
#   Статус:         bash scripts/protect-soul.sh status
#   Разблокировать: bash scripts/protect-soul.sh unlock
###############################################################################

set -euo pipefail

MODE="${1:-deploy}"
SOUL_UPDATE_SRC="${2:-}"

# ── G-05: parse governance flags (--approver, --role, --reason) ───────────────
GOV_APPROVER=""
GOV_ROLE=""
GOV_REASON=""
_shift_count=2
_args=("$@")
_idx=0
for _arg in "${_args[@]}"; do
    case "$_arg" in
        --approver) GOV_APPROVER="${_args[$((_idx+1))]+${_args[$((_idx+1))]}}" ;;
        --role)     GOV_ROLE="${_args[$((_idx+1))]+${_args[$((_idx+1))]}}" ;;
        --reason)   GOV_REASON="${_args[$((_idx+1))]+${_args[$((_idx+1))]}}" ;;
    esac
    _idx=$((_idx+1))
done

VIBE_DIR="${VIBE_DIR:-$HOME/vibe-coding}"
GOVERNANCE_PY="$VIBE_DIR/src/compliance/governance/soul_governance.py"

REMOTE="gmktec"
LOG_FILE="/data/logs/soul-protect.log"

SOUL_PROTECTED="/home/mmber/.openclaw-moa/soul-protected/SOUL.md"
WORKSPACE_ROOT="/root/.openclaw-moa/workspace-moa/SOUL.md"
WORKSPACE_MMBER="/home/mmber/.openclaw/workspace-moa/SOUL.md"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

###############################################################################
# STATUS — показать текущее состояние защиты
###############################################################################
cmd_status() {
    log "=== Статус защиты SOUL.md ==="
    echo ""
    echo "📂 soul-protected (источник истины):"
    stat --format="  size=%s bytes  modified=%y" "$SOUL_PROTECTED" 2>/dev/null || echo "  ОТСУТСТВУЕТ!"
    echo ""
    echo "🤖 Workspace main agent (root):"
    ATTR=$(lsattr "$WORKSPACE_ROOT" 2>/dev/null | awk '{print $1}')
    if echo "$ATTR" | grep -q 'i'; then
        echo "  ✅ ЗАЩИЩЁН (chattr +i)"
    else
        echo "  ❌ НЕ ЗАЩИЩЁН (уязвим к перезаписи)"
    fi
    stat --format="  size=%s bytes  modified=%y" "$WORKSPACE_ROOT" 2>/dev/null || echo "  ОТСУТСТВУЕТ!"
    echo ""
    echo "🏠 Workspace defaults (mmber):"
    ATTR2=$(lsattr "$WORKSPACE_MMBER" 2>/dev/null | awk '{print $1}')
    if echo "$ATTR2" | grep -q 'i'; then
        echo "  ✅ ЗАЩИЩЁН (chattr +i)"
    else
        echo "  ❌ НЕ ЗАЩИЩЁН"
    fi
    stat --format="  size=%s bytes  modified=%y" "$WORKSPACE_MMBER" 2>/dev/null || echo "  ОТСУТСТВУЕТ!"
    echo ""
}

###############################################################################
# DEPLOY — первоначальный деплой: soul-protected → workspaces + chattr +i
###############################################################################
cmd_deploy() {
    log "=== Деплой защиты SOUL.md ==="

    # 1. Проверяем наличие soul-protected
    if [ ! -f "$SOUL_PROTECTED" ]; then
        log "❌ $SOUL_PROTECTED не найден! Создайте сначала soul-protected/SOUL.md"
        exit 1
    fi

    SOUL_SIZE=$(wc -c < "$SOUL_PROTECTED")
    log "Источник: $SOUL_PROTECTED ($SOUL_SIZE bytes)"

    # 2. Деплой в root workspace (root-owned → sudo cp + sudo chattr)
    log "Деплой в root workspace..."
    sudo chattr -i "$WORKSPACE_ROOT" 2>/dev/null || true
    sudo cp "$SOUL_PROTECTED" "$WORKSPACE_ROOT"
    sudo chattr +i "$WORKSPACE_ROOT"
    log "✅ $WORKSPACE_ROOT → защищён"

    # 3. Деплой в mmber workspace (user-owned → cp без sudo, chattr требует sudo)
    log "Деплой в mmber workspace..."
    sudo chattr -i "$WORKSPACE_MMBER" 2>/dev/null || true
    cp "$SOUL_PROTECTED" "$WORKSPACE_MMBER"
    sudo chattr +i "$WORKSPACE_MMBER"
    log "✅ $WORKSPACE_MMBER → защищён"

    # 4. Проверка
    log "Проверка атрибутов..."
    sudo lsattr "$WORKSPACE_ROOT" && lsattr "$WORKSPACE_MMBER"

    log "=== Деплой завершён ==="
}

###############################################################################
# UPDATE — обновить SOUL.md из нового файла
# G-05: требует --approver + --role + --reason (CLASS_B governance gate)
###############################################################################
cmd_update() {
    if [ -z "$SOUL_UPDATE_SRC" ]; then
        log "❌ Укажите путь к новому SOUL.md: $0 update /path/to/SOUL.md --approver <id> --role <role> --reason '<text>'"
        exit 1
    fi
    if [ ! -f "$SOUL_UPDATE_SRC" ]; then
        log "❌ Файл не найден: $SOUL_UPDATE_SRC"
        exit 1
    fi

    log "=== Обновление SOUL.md ==="
    log "Источник: $SOUL_UPDATE_SRC"

    # ── G-05: Governance gate ──────────────────────────────────────────────────
    if [ -f "$GOVERNANCE_PY" ] && command -v python3 &>/dev/null; then
        log "[G-05] Проверка governance gate (CLASS_B)..."

        GOV_ARGS=(check --target "docs/SOUL.md" --proposed-by "protect-soul.sh")
        if [ -n "$GOV_APPROVER" ]; then
            GOV_ARGS+=(--approver "$GOV_APPROVER")
        fi
        if [ -n "$GOV_ROLE" ]; then
            GOV_ARGS+=(--role "$GOV_ROLE")
        fi
        if [ -n "$GOV_REASON" ]; then
            GOV_ARGS+=(--reason "$GOV_REASON")
        fi

        if ! python3 "$GOVERNANCE_PY" "${GOV_ARGS[@]}" 2>&1; then
            log "❌ Governance gate BLOCKED — укажите --approver, --role и --reason"
            log "   Пример: bash scripts/protect-soul.sh update $SOUL_UPDATE_SRC \\"
            log "             --approver mark-001 --role DEVELOPER --reason 'quarterly SOUL update'"
            exit 1
        fi
        log "✅ Governance gate APPROVED"
    else
        log "⚠️  [G-05] Governance module недоступен — update выполнен без gate (legacy mode)"
    fi

    # Обновляем soul-protected (user-owned path, mkdir -p на случай первого запуска)
    mkdir -p "$(dirname "$SOUL_PROTECTED")"
    cp "$SOUL_UPDATE_SRC" "$SOUL_PROTECTED"
    log "✅ soul-protected обновлён"

    # Деплоим в workspaces
    cmd_deploy
}

###############################################################################
# UNLOCK — временно снять защиту (для ручного редактирования)
###############################################################################
cmd_unlock() {
    log "=== Снятие защиты SOUL.md (временно) ==="
    sudo chattr -i "$WORKSPACE_ROOT" 2>/dev/null && log "✅ root workspace разблокирован" || true
    sudo chattr -i "$WORKSPACE_MMBER" 2>/dev/null && log "✅ mmber workspace разблокирован" || true
    log "⚠️  Не забудьте запустить: bash scripts/protect-soul.sh deploy — после редактирования"
}

###############################################################################
# VERIFY — проверить что SOUL.md не изменился (вызывается из watcher)
###############################################################################
cmd_verify() {
    PROTECTED_HASH=$(md5sum "$SOUL_PROTECTED" 2>/dev/null | awk '{print $1}')
    ROOT_HASH=$(md5sum "$WORKSPACE_ROOT" 2>/dev/null | awk '{print $1}')
    MMBER_HASH=$(md5sum "$WORKSPACE_MMBER" 2>/dev/null | awk '{print $1}')

    CHANGED=0

    if [ "$ROOT_HASH" != "$PROTECTED_HASH" ]; then
        log "⚠️  SOUL.md в root workspace изменился! Восстанавливаю..." >> "$LOG_FILE"
        sudo chattr -i "$WORKSPACE_ROOT" 2>/dev/null || true
        sudo cp "$SOUL_PROTECTED" "$WORKSPACE_ROOT"
        sudo chattr +i "$WORKSPACE_ROOT"
        log "✅ root workspace SOUL.md восстановлен" >> "$LOG_FILE"
        CHANGED=1
    fi

    if [ "$MMBER_HASH" != "$PROTECTED_HASH" ]; then
        log "⚠️  SOUL.md в mmber workspace изменился! Восстанавливаю..." >> "$LOG_FILE"
        sudo chattr -i "$WORKSPACE_MMBER" 2>/dev/null || true
        cp "$SOUL_PROTECTED" "$WORKSPACE_MMBER"
        sudo chattr +i "$WORKSPACE_MMBER"
        log "✅ mmber workspace SOUL.md восстановлен" >> "$LOG_FILE"
        CHANGED=1
    fi

    if [ "$CHANGED" -eq 0 ]; then
        exit 0
    fi
}

###############################################################################
# MAIN
###############################################################################
case "$MODE" in
    deploy)   cmd_deploy   ;;
    update)   cmd_update   ;;
    unlock)   cmd_unlock   ;;
    status)   cmd_status   ;;
    verify)   cmd_verify   ;;
    *)
        echo "Использование: $0 {deploy|update|unlock|status|verify}"
        exit 1
        ;;
esac
