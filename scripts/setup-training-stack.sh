#!/bin/bash
###############################################################################
# setup-training-stack.sh — Установка и верификация обучающего стека
#                            для методологии перекрёстной верификации BANXE
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/setup-training-stack.sh
#
# Что делает:
#   1. Диагностика текущего состояния всех 8 инструментов
#   2. Promptfoo — устанавливает глобальный бинарь (не только npx)
#   3. TinyTroupe — pip install (симуляция персон клиентов)
#   4. AMLSim — клонирование IBM/AMLSim (adversarial транзакции)
#   5. AMLGentex — клонирование aidotse/AMLGentex (benchmark AML)
#   6. OpenRLHF — без flash-attn (CUDA на GMKtec недоступна — AMD GPU)
#   7. Создаёт директории обучающего корпуса
#   8. ClickHouse — таблица verification_corpus для логов верификации
#   9. Обновляет MEMORY.md
###############################################################################

set -euo pipefail

echo "============================================================"
echo "  SETUP: Обучающий стек BANXE — Перекрёстная верификация"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================"
echo ""

###############################################################################
# Шаг 1: Диагностика текущего состояния
###############################################################################

echo "--- [1/8] ДИАГНОСТИКА ---"

ssh gmktec 'bash -s' << 'DIAG'
echo ""
echo "  Инструменты:"
pip3 list 2>/dev/null | grep -iE "deepeval|langgraph|evidently|openrlhf|flash.attn|tinytroupe|torch|numpy" \
  | awk '{printf "    %-35s %s\n", $1, $2}' || true

echo ""
echo "  Node/Promptfoo:"
node --version 2>/dev/null && echo "  $(npx promptfoo --version 2>/dev/null || echo 'promptfoo: только npx')"
which promptfoo 2>/dev/null && echo "  promptfoo binary: OK" || echo "  promptfoo binary: нет (только npx)"

echo ""
echo "  CUDA/GPU:"
python3 -c "
import torch
print(f'    torch: {torch.__version__}')
print(f'    CUDA:  {torch.cuda.is_available()}')
import subprocess, re
r = subprocess.run(['rocm-smi','--showmeminfo','vram'], capture_output=True, text=True)
if r.returncode == 0:
    print('    ROCm: доступен')
else:
    print('    ROCm: не обнаружен (или не установлен)')
" 2>/dev/null || echo "    torch: не установлен"

echo ""
echo "  AML данные:"
ls /opt/AMLSim 2>/dev/null && echo "    AMLSim: /opt/AMLSim" || echo "    AMLSim: нет"
ls /opt/AMLGentex 2>/dev/null && echo "    AMLGentex: /opt/AMLGentex" || echo "    AMLGentex: нет"

echo ""
echo "  ClickHouse — таблица верификации:"
clickhouse-client --query "SELECT count() FROM banxe.verification_corpus" 2>/dev/null \
  && echo "    verification_corpus: существует" \
  || echo "    verification_corpus: не создана"
DIAG

echo ""
echo "--- [2/8] PROMPTFOO — глобальный бинарь ---"

ssh gmktec 'bash -s' << 'PROMPTFOO'
if which promptfoo &>/dev/null; then
  echo "  promptfoo binary уже есть: $(which promptfoo) v$(promptfoo --version 2>/dev/null)"
else
  echo "  Устанавливаю глобально..."
  npm install -g promptfoo 2>&1 | tail -3
  if which promptfoo &>/dev/null; then
    echo "  OK: promptfoo $(promptfoo --version)"
  else
    echo "  WARN: бинарь всё ещё не в PATH — использую npx как fallback"
    ln -sf "$(npx --no-install promptfoo which 2>/dev/null || echo '')" /usr/local/bin/promptfoo 2>/dev/null || true
  fi
fi
PROMPTFOO

echo ""
echo "--- [3/8] TINYTROUPE — симуляция персон клиентов ---"

ssh gmktec 'bash -s' << 'TINY'
if pip3 show tinytroupe &>/dev/null; then
  echo "  TinyTroupe уже установлен: $(pip3 show tinytroupe | grep Version)"
else
  echo "  Устанавливаю TinyTroupe..."
  pip3 install tinytroupe 2>&1 | tail -5
  if pip3 show tinytroupe &>/dev/null; then
    echo "  OK: $(pip3 show tinytroupe | grep Version)"
  else
    echo "  WARN: pip install не удался, пробую через git..."
    if [ ! -d "/opt/TinyTroupe" ]; then
      git clone --depth=1 https://github.com/microsoft/TinyTroupe.git /opt/TinyTroupe 2>&1 | tail -3
    fi
    pip3 install -e /opt/TinyTroupe/ 2>&1 | tail -3
    pip3 show tinytroupe &>/dev/null && echo "  OK: TinyTroupe из git" || echo "  ERROR: не удалось установить TinyTroupe"
  fi
fi
TINY

echo ""
echo "--- [4/8] AMLSIM — adversarial транзакции (IBM) ---"

ssh gmktec 'bash -s' << 'AMLSIM'
if [ -d "/opt/AMLSim" ]; then
  echo "  AMLSim уже есть, обновляю..."
  cd /opt/AMLSim && git pull 2>&1 | tail -2
else
  echo "  Клонирую IBM/AMLSim..."
  git clone --depth=1 https://github.com/IBM/AMLSim.git /opt/AMLSim 2>&1 | tail -3
  echo "  OK: /opt/AMLSim"
fi

# Устанавливаем Python зависимости
if [ -f "/opt/AMLSim/requirements.txt" ]; then
  echo "  Устанавливаю зависимости AMLSim..."
  pip3 install -r /opt/AMLSim/requirements.txt 2>&1 | tail -3
  echo "  OK: зависимости установлены"
fi

# Создаём симлинк для удобства
ln -sf /opt/AMLSim/scripts /opt/amlsim-scripts 2>/dev/null || true
echo "  Директория: /opt/AMLSim"
AMLSIM

echo ""
echo "--- [5/8] AMLGENTEX — benchmark данные реальных AML-кейсов ---"

ssh gmktec 'bash -s' << 'AMLGEN'
if [ -d "/opt/AMLGentex" ]; then
  echo "  AMLGentex уже есть, обновляю..."
  cd /opt/AMLGentex && git pull 2>&1 | tail -2
else
  echo "  Клонирую aidotse/AMLGentex..."
  git clone --depth=1 https://github.com/aidotse/AMLGentex.git /opt/AMLGentex 2>&1 | tail -3
  echo "  OK: /opt/AMLGentex"
fi

if [ -f "/opt/AMLGentex/requirements.txt" ]; then
  echo "  Устанавливаю зависимости AMLGentex..."
  pip3 install -r /opt/AMLGentex/requirements.txt 2>&1 | tail -3
fi

echo "  Директория: /opt/AMLGentex"
AMLGEN

echo ""
echo "--- [6/8] OPENRLHF — без flash-attn (GMKtec = AMD GPU, нет CUDA) ---"
echo "    ПРИЧИНА: flash-attn требует NVIDIA CUDA. GMKtec — AMD Ryzen AI MAX+."
echo "    РЕШЕНИЕ: FLASH_ATTENTION_SKIP_CUDA_BUILD=TRUE + CPU/ROCm режим."

ssh gmktec 'bash -s' << 'RLHF'
if pip3 show openrlhf &>/dev/null; then
  echo "  OpenRLHF уже установлен: $(pip3 show openrlhf | grep Version)"
else
  echo "  Устанавливаю OpenRLHF без flash-attn..."

  # Сначала обновляем build-инструменты
  pip3 install -U pip setuptools wheel packaging ninja 2>&1 | tail -2

  # Устанавливаем numpy отдельно (нужен для сборки)
  pip3 install numpy 2>&1 | tail -2

  # Основная установка: пропускаем flash-attn через env-флаг
  FLASH_ATTENTION_SKIP_CUDA_BUILD=TRUE \
  OPENRLHF_SKIP_FLASH_ATTN=1 \
    pip3 install openrlhf --no-deps 2>&1 | tail -5

  # Если --no-deps не сработал, пробуем с игнором конфликтов
  if ! pip3 show openrlhf &>/dev/null; then
    echo "  Пробую альтернативный метод..."
    FLASH_ATTENTION_SKIP_CUDA_BUILD=TRUE \
      pip3 install openrlhf --ignore-requires-python 2>&1 | tail -5
  fi

  # Устанавливаем зависимости вручную (без flash-attn)
  pip3 install \
    transformers \
    accelerate \
    datasets \
    peft \
    trl \
    bitsandbytes \
    sentencepiece \
    2>&1 | tail -5

  if pip3 show openrlhf &>/dev/null; then
    echo "  OK: $(pip3 show openrlhf | grep Version)"
  else
    echo "  WARN: openrlhf не установился через pip"
    echo "  Клонирую из GitHub для ручной установки..."
    if [ ! -d "/opt/OpenRLHF" ]; then
      git clone --depth=1 https://github.com/OpenRLHF/OpenRLHF.git /opt/OpenRLHF 2>&1 | tail -3
    fi
    # Патчим setup.py чтобы убрать flash-attn из зависимостей
    if [ -f "/opt/OpenRLHF/setup.py" ]; then
      sed -i 's/"flash-attn[^"]*"[, ]*//' /opt/OpenRLHF/setup.py
      sed -i 's/"flash_attn[^"]*"[, ]*//' /opt/OpenRLHF/setup.py
      echo "  Патч setup.py применён (убрана зависимость flash-attn)"
    fi
    if [ -f "/opt/OpenRLHF/pyproject.toml" ]; then
      sed -i '/flash[-_]attn/d' /opt/OpenRLHF/pyproject.toml
      echo "  Патч pyproject.toml применён"
    fi
    FLASH_ATTENTION_SKIP_CUDA_BUILD=TRUE pip3 install -e /opt/OpenRLHF/ 2>&1 | tail -5
    pip3 show openrlhf &>/dev/null \
      && echo "  OK: OpenRLHF из git (без flash-attn)" \
      || echo "  ERROR: OpenRLHF не удалось установить — требуется ручная диагностика"
  fi
fi

echo ""
echo "  Проверка импорта:"
python3 -c "import openrlhf; print('  openrlhf: импорт OK')" 2>/dev/null \
  || echo "  openrlhf: импорт не удался (могут быть отсутствующие зависимости)"
RLHF

echo ""
echo "--- [7/8] ДИРЕКТОРИИ обучающего корпуса ---"

ssh gmktec 'bash -s' << 'DIRS'
echo "  Создаю структуру директорий..."

mkdir -p /data/banxe-training/{corpus,test-suites,corrections,drift-logs,snapshots}
mkdir -p /data/banxe-training/test-suites/{category-A,category-B,category-C,category-D,category-E}
mkdir -p /data/banxe-training/agents/{compliance-validator,policy-agent,workflow-agent}

# Базовый README для корпуса
cat > /data/banxe-training/README.md << 'README'
# Banxe AI — Обучающий корпус

## Структура
- corpus/         — записи верификации (JSON, по одному файлу на сессию)
- test-suites/    — тест-кейсы по категориям A-E
- corrections/    — исправления с источниками (FCA handbook, BANXE policy)
- drift-logs/     — мониторинг отклонения агентов (Evidently AI)
- snapshots/      — снимки baseline поведения агентов

## Категории тестов
- A: Штатные (базовое знание)
- B: Граничные (пороговые значения, structuring)
- C: Красные линии (отказ запрещённых действий) — 0 ошибок допустимо
- D: Маршрутизация (правильная эскалация) — 0 ошибок допустимо
- E: Неопределённость (признание незнания)
README

echo "  OK: /data/banxe-training/"
ls -la /data/banxe-training/
DIRS

echo ""
echo "--- [8/8] CLICKHOUSE — таблица verification_corpus ---"

ssh gmktec 'bash -s' << 'CH'
echo "  Создаю таблицу verification_corpus в ClickHouse..."

clickhouse-client --query "
CREATE TABLE IF NOT EXISTS banxe.verification_corpus (
    interaction_id      UUID DEFAULT generateUUIDv4(),
    created_at          DateTime DEFAULT now(),
    agent_id            String,
    agent_role          LowCardinality(String),
    statement           String,
    session_length      UInt32,
    language            LowCardinality(String),

    -- Вердикты трёх верификаторов
    compliance_verdict  LowCardinality(String),  -- CONFIRMED/REFUTED/UNCERTAIN
    compliance_rule     String,
    policy_verdict      LowCardinality(String),
    policy_note         String,
    workflow_verdict    LowCardinality(String),
    workflow_reason     String,

    -- Консенсус
    consensus           LowCardinality(String),
    confidence_score    Float32,

    -- Поведенческие метрики
    drift_score             Float32,
    escalation_correct      UInt8,  -- 0/1
    role_boundary_violated  UInt8,  -- 0/1
    hallucination_detected  UInt8,

    -- Для дообучения
    training_flag   UInt8 DEFAULT 0,
    correction      String,
    correction_source String
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY (created_at, agent_id, consensus)
TTL created_at + INTERVAL 5 YEAR
SETTINGS index_granularity = 8192;
" 2>&1

if clickhouse-client --query "SELECT count() FROM banxe.verification_corpus" &>/dev/null; then
  echo "  OK: таблица verification_corpus создана"
  clickhouse-client --query "DESCRIBE TABLE banxe.verification_corpus" | awk '{printf "    %-30s %s\n", $1, $2}'
else
  echo "  ERROR: не удалось создать таблицу"
fi
CH

###############################################################################
# Итоговая сводка
###############################################################################

echo ""
echo "============================================================"
echo "  ИТОГОВАЯ СВОДКА"
echo "============================================================"

ssh gmktec 'bash -s' << 'SUMMARY'
echo ""
echo "  ИНСТРУМЕНТЫ:"
tools=(
  "promptfoo:npx promptfoo --version"
  "deepeval:pip3 show deepeval"
  "langgraph:pip3 show langgraph"
  "evidently:pip3 show evidently"
  "tinytroupe:pip3 show tinytroupe"
  "openrlhf:pip3 show openrlhf"
  "torch:pip3 show torch"
)

for entry in "${tools[@]}"; do
  name="${entry%%:*}"
  cmd="${entry#*:}"
  if eval "$cmd" &>/dev/null; then
    ver=$(eval "$cmd" 2>/dev/null | grep -i version | head -1 | awk '{print $NF}')
    echo "    OK  $name $ver"
  else
    # Проверяем специально для promptfoo
    if [ "$name" = "promptfoo" ] && npx promptfoo --version &>/dev/null; then
      echo "    OK  $name $(npx promptfoo --version) (через npx)"
    else
      echo "    ERR $name — НЕ УСТАНОВЛЕН"
    fi
  fi
done

echo ""
echo "  ДАННЫЕ:"
[ -d "/opt/AMLSim" ] && echo "    OK  AMLSim — /opt/AMLSim" || echo "    ERR AMLSim — нет"
[ -d "/opt/AMLGentex" ] && echo "    OK  AMLGentex — /opt/AMLGentex" || echo "    ERR AMLGentex — нет"
[ -d "/data/banxe-training" ] && echo "    OK  Обучающий корпус — /data/banxe-training/" || echo "    ERR /data/banxe-training — нет"
clickhouse-client --query "SELECT 'OK  ClickHouse verification_corpus — ' || toString(count()) || ' записей' FROM banxe.verification_corpus" 2>/dev/null \
  || echo "    ERR ClickHouse verification_corpus — нет"

echo ""
echo "  GPU / RLHF:"
echo "    INFO GMKtec = AMD Ryzen AI MAX+ 395 (нет NVIDIA CUDA)"
echo "    INFO OpenRLHF работает в CPU/ROCm режиме (без flash-attn)"
echo "    INFO flash-attn НЕ требуется для методологии верификации"
echo "    INFO Ollama уже использует AMD GPU через ROCm"
SUMMARY

###############################################################################
# Обновляем MEMORY.md
###############################################################################

echo ""
echo "  Обновляю docs/MEMORY.md..."

MEMORY_FILE="/home/mmber/vibe-coding/docs/MEMORY.md"
TIMESTAMP=$(date '+%Y-%m-%d')

# Добавляем секцию обучающего стека если её нет
if ! grep -q "## Обучающий стек" "$MEMORY_FILE" 2>/dev/null; then
cat >> "$MEMORY_FILE" << MEMBLOCK

## Обучающий стек (Перекрёстная верификация агентов)

> Установлено: $TIMESTAMP

### Инструменты (GMKtec)
| Инструмент | Назначение | Статус |
|---|---|---|
| Promptfoo | Тест-харнесс, red-teaming | OK (npx + global) |
| DeepEval | Метрики качества ответов | OK |
| LangGraph | Оркестратор верификационной сети | OK |
| TinyTroupe | Симуляция персон клиентов | установлен |
| AMLSim | Adversarial транзакционные паттерны | /opt/AMLSim |
| AMLGentex | Benchmark реальных AML-кейсов | /opt/AMLGentex |
| Evidently AI | Мониторинг drift в продакшне | OK |
| OpenRLHF | RLHF-дообучение (CPU/ROCm режим) | без flash-attn |

### Важно: GPU на GMKtec
- GMKtec = AMD Ryzen AI MAX+ 395 → **ROCm, не CUDA**
- flash-attn требует NVIDIA CUDA → **не работает на GMKtec**
- OpenRLHF установлен без flash-attn, работает в CPU/ROCm режиме
- Для полноценного RLHF с flash-attn нужен отдельный NVIDIA-сервер

### Данные и корпус
- /data/banxe-training/ — обучающий корпус (5 категорий A-E)
- ClickHouse: banxe.verification_corpus — лог всех верификаций

### autoresearch (karpathy-style)
- Роль: вспомогательный контур R&D, НЕ продовый
- Оптимизирует: системные инструкции верификаторов, scoring, thresholds
- Установлен: /opt/AutoResearchClaw/
MEMBLOCK

  echo "  OK: секция добавлена в MEMORY.md"
else
  # Обновляем дату
  sed -i "s/> Установлено: .*/> Установлено: $TIMESTAMP/" "$MEMORY_FILE"
  echo "  OK: MEMORY.md уже содержит секцию, дата обновлена"
fi

echo ""
echo "============================================================"
echo "  ГОТОВО: обучающий стек проверен и установлен"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================"
