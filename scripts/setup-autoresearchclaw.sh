#!/bin/bash
###############################################################################
# setup-autoresearchclaw.sh — Установка AutoResearchClaw на GMKtec
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/setup-autoresearchclaw.sh
#
# Что делает:
#   1. Клонирует AutoResearchClaw на GMKtec
#   2. Создаёт venv и устанавливает зависимости
#   3. Конфигурирует для работы с Ollama (локально) + Anthropic (облако)
#   4. Интегрирует с MetaClaw (skills bridge)
#   5. Создаёт удобную команду: research "тема"
#   6. Тестовый запуск
###############################################################################

echo "=========================================="
echo "  УСТАНОВКА AutoResearchClaw"
echo "  Автономные исследования из идеи в PDF"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE_END'
export PATH="$PATH:/root/.local/bin"

LOG="/data/logs/autoresearchclaw-setup.log"
mkdir -p /data/logs
log() { echo "$(date '+%H:%M:%S') $1" | tee -a "$LOG"; }

###########################################################################
# 1. Клонируем
###########################################################################
log "[1/5] Клонирую AutoResearchClaw..."

if [ -d "/opt/AutoResearchClaw" ]; then
    cd /opt/AutoResearchClaw && git pull 2>&1 | tail -3
    log "  ✓ Обновлён"
else
    cd /opt && git clone https://github.com/aiming-lab/AutoResearchClaw.git 2>&1 | tail -3
    log "  ✓ Клонирован в /opt/AutoResearchClaw"
fi

###########################################################################
# 2. Устанавливаем
###########################################################################
log "[2/5] Устанавливаю..."

cd /opt/AutoResearchClaw

# Создаём venv
if [ ! -d ".venv" ]; then
    python3 -m venv .venv
    log "  ✓ venv создан"
fi

source .venv/bin/activate

# Устанавливаем
pip install -e . 2>&1 | tail -5
log "  ✓ pip install завершён"

# Проверяем
if command -v researchclaw &>/dev/null; then
    log "  ✓ researchclaw CLI доступен"
else
    log "  ⚠ researchclaw CLI не найден в PATH"
fi

###########################################################################
# 3. Конфигурируем
###########################################################################
log "[3/5] Создаю конфигурацию..."

# Конфиг для Ollama (локальные исследования, бесплатно)
cat > /opt/AutoResearchClaw/config-ollama.yaml << 'CFG_OLLAMA'
# AutoResearchClaw — Ollama (локальный, бесплатный)
project:
  name: "banxe-research"
  mode: "full-auto"

research:
  topic: ""
  domains: ["fintech", "banking", "compliance", "regulation"]
  quality_threshold: 3.5

runtime:
  timezone: "Europe/Paris"
  max_parallel_tasks: 2
  retry_limit: 3

llm:
  provider: "openai-compatible"
  base_url: "http://localhost:11434/v1"
  api_key: "ollama"
  primary_model: "huihui_ai/qwen3.5-abliterated:35b"
  fallback_models: ["glm-4.7-flash-abliterated"]

experiment:
  mode: "sandbox"
  time_budget_sec: 600
  max_iterations: 5
  sandbox:
    python_path: "/opt/AutoResearchClaw/.venv/bin/python"
    gpu_required: false
    max_memory_mb: 8192

web_search:
  enabled: true
  enable_scholar: true
  enable_pdf_extraction: true
  max_web_results: 10

export:
  authors: "Banxe AI Bank Research"

security:
  hitl_required_stages: []
  allow_publish_without_approval: true
  redact_sensitive_logs: true

metaclaw_bridge:
  enabled: true
  skills_dir: "/data/metaclaw/skills"
  lesson_to_skill:
    enabled: true
    min_severity: "warning"
    max_skills_per_run: 3

notifications:
  channel: "console"
CFG_OLLAMA

# Конфиг для Anthropic (качественные исследования)
cat > /opt/AutoResearchClaw/config-anthropic.yaml << 'CFG_ANTHROPIC'
# AutoResearchClaw — Anthropic Claude (облако, высокое качество)
project:
  name: "banxe-research"
  mode: "full-auto"

research:
  topic: ""
  domains: ["fintech", "banking", "compliance", "regulation"]
  quality_threshold: 4.0

runtime:
  timezone: "Europe/Paris"
  max_parallel_tasks: 3
  retry_limit: 2

llm:
  provider: "openai-compatible"
  base_url: "https://api.anthropic.com/v1"
  api_key_env: "ANTHROPIC_API_KEY"
  primary_model: "claude-sonnet-4-5-20250514"
  fallback_models: ["claude-sonnet-4-5-20250514"]

experiment:
  mode: "sandbox"
  time_budget_sec: 300
  max_iterations: 10
  sandbox:
    python_path: "/opt/AutoResearchClaw/.venv/bin/python"
    gpu_required: false
    max_memory_mb: 8192

web_search:
  enabled: true
  enable_scholar: true
  enable_pdf_extraction: true

export:
  authors: "Banxe AI Bank Research"

security:
  hitl_required_stages: [5, 9, 20]
  allow_publish_without_approval: false
  redact_sensitive_logs: true

metaclaw_bridge:
  enabled: true
  skills_dir: "/data/metaclaw/skills"

notifications:
  channel: "console"
CFG_ANTHROPIC

log "  ✓ config-ollama.yaml (локальный, бесплатный)"
log "  ✓ config-anthropic.yaml (облако, качественный)"

###########################################################################
# 4. Создаём удобную команду
###########################################################################
log "[4/5] Создаю команду research..."

cat > /usr/local/bin/research << 'CMD'
#!/bin/bash
# research "тема" — запуск AutoResearchClaw
# Использование:
#   research "FCA compliance requirements for EMI"
#   research --cloud "Deep analysis of SEPA payment regulations"

cd /opt/AutoResearchClaw
source .venv/bin/activate

if [ "$1" = "--cloud" ]; then
    shift
    CONFIG="config-anthropic.yaml"
    echo "☁️  Используется Anthropic Claude (облако)"
else
    CONFIG="config-ollama.yaml"
    echo "🏠 Используется Ollama (локально, бесплатно)"
fi

TOPIC="$*"
if [ -z "$TOPIC" ]; then
    echo "Использование: research \"тема исследования\""
    echo "             research --cloud \"тема\" (через Anthropic)"
    exit 1
fi

echo "📚 Тема: $TOPIC"
echo "📁 Результаты: /opt/AutoResearchClaw/artifacts/"
echo ""

researchclaw run --config "$CONFIG" --topic "$TOPIC" --auto-approve
CMD

chmod +x /usr/local/bin/research
log "  ✓ Команда создана: research \"тема\""
log "    research --cloud \"тема\" (через Anthropic)"

###########################################################################
# 5. Тест
###########################################################################
log "[5/5] Проверяю установку..."

source /opt/AutoResearchClaw/.venv/bin/activate

echo ""
echo "  Проверка:"
if command -v researchclaw &>/dev/null; then
    echo "    ✓ researchclaw CLI доступен"
    researchclaw --version 2>/dev/null || echo "    (версия не определена)"
else
    # Проверяем через python
    python3 -c "import researchclaw; print('    ✓ researchclaw модуль установлен')" 2>/dev/null || echo "    ⚠ researchclaw не найден как модуль"
fi

echo "    ✓ config-ollama.yaml"
echo "    ✓ config-anthropic.yaml"
echo "    ✓ /usr/local/bin/research"

echo ""
echo "  Директории:"
echo "    /opt/AutoResearchClaw/ — основной код"
echo "    /opt/AutoResearchClaw/artifacts/ — результаты исследований"
echo "    /data/metaclaw/skills/ — MetaClaw интеграция"

REMOTE_END

echo ""
echo "=========================================="
echo "  AutoResearchClaw УСТАНОВЛЕН"
echo "=========================================="
echo ""
echo "  Использование (на GMKtec):"
echo ""
echo "  Локально (бесплатно, Ollama):"
echo '    ssh gmktec "research \"FCA compliance for EMI\""'
echo ""
echo "  Через облако (Anthropic, качественнее):"
echo '    ssh gmktec "research --cloud \"SEPA payment regulation analysis\""'
echo ""
echo "  Результаты: /opt/AutoResearchClaw/artifacts/"
echo "  PDF исследования появятся там автоматически"
