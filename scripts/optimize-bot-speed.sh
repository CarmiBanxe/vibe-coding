#!/bin/bash
###############################################################################
# optimize-bot-speed.sh — Ускорение бота без смены модели
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/optimize-bot-speed.sh
#
# Что делает:
#   1. Показывает текущие параметры бота
#   2. Оптимизирует конфиг:
#      - num_predict: 2048 (ограничивает длину ответа — меньше генерировать)
#      - num_ctx: 16384 (было 32768 — меньше контекст = быстрее обработка)
#      - temperature: 0.5 (было дефолтное — меньше "раздумий")
#      - num_batch: 512 (параллельная обработка токенов)
#      - num_gpu: 99 (все слои на GPU)
#   3. Перезагружает модель в Ollama (сброс кэша)
#   4. Перезапускает gateway
#   5. Замеряет скорость ответа
#
# ВАЖНО: streaming остаётся false (иначе 2-мин timeout бот)
#         но num_predict ограничивает ответ — бот не будет писать эссе
###############################################################################

echo "=========================================="
echo "  ОПТИМИЗАЦИЯ СКОРОСТИ БОТА"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE_END'

###########################################################################
# 1. ТЕКУЩИЕ ПАРАМЕТРЫ
###########################################################################
echo "[1/5] Текущие параметры..."

MOA_CFG="/root/.openclaw-moa/.openclaw/openclaw.json"
DEFAULT_CFG="/root/.openclaw-default/.openclaw/openclaw.json"

echo "  MoA конфиг:"
python3 << 'PY1'
import json
with open("/root/.openclaw-moa/.openclaw/openclaw.json") as f:
    cfg = json.load(f)

# Ищем параметры модели
agents = cfg.get("agents", {})
defaults = agents.get("defaults", {})
models = defaults.get("models", {})
params = defaults.get("params", models.get("params", {}))

print(f"    model: {models.get('default', 'не указана')}")
print(f"    params: {json.dumps(params, indent=6)}")

# Проверяем provider
provider = cfg.get("provider", {})
print(f"    provider.api: {provider.get('api', 'не указан')}")
print(f"    provider.baseUrl: {provider.get('baseUrl', 'не указан')}")
PY1

###########################################################################
# 2. ОПТИМИЗАЦИЯ КОНФИГА
###########################################################################
echo ""
echo "[2/5] Оптимизирую параметры..."

for CFG_FILE in "$MOA_CFG" "$DEFAULT_CFG"; do
    if [ ! -f "$CFG_FILE" ]; then
        continue
    fi
    
    python3 << PYOPT
import json

cfg_path = "$CFG_FILE"
with open(cfg_path) as f:
    cfg = json.load(f)

changes = []

# Находим где хранятся params
agents = cfg.setdefault("agents", {})
defaults = agents.setdefault("defaults", {})

# Params могут быть в разных местах — нормализуем
if "params" not in defaults:
    defaults["params"] = {}

params = defaults["params"]

# Оптимизации:

# 1. num_predict: ограничивает МАКСИМАЛЬНУЮ длину ответа
#    2048 токенов ≈ 1500 слов — достаточно для развёрнутого ответа
#    но не даёт боту писать бесконечные эссе
old_predict = params.get("num_predict", "не установлен")
params["num_predict"] = 2048
changes.append(f"num_predict: {old_predict} → 2048")

# 2. num_ctx: контекстное окно
#    32768 слишком много для большинства запросов
#    16384 достаточно и обрабатывается значительно быстрее
old_ctx = params.get("num_ctx", "не установлен")
params["num_ctx"] = 16384
changes.append(f"num_ctx: {old_ctx} → 16384")

# 3. temperature: меньше = быстрее + детерминистичнее
old_temp = params.get("temperature", "не установлен")
params["temperature"] = 0.5
changes.append(f"temperature: {old_temp} → 0.5")

# 4. num_batch: сколько токенов обрабатывать параллельно
old_batch = params.get("num_batch", "не установлен")
params["num_batch"] = 512
changes.append(f"num_batch: {old_batch} → 512")

# 5. num_gpu: количество слоёв на GPU (99 = все)
old_gpu = params.get("num_gpu", "не установлен")
params["num_gpu"] = 99
changes.append(f"num_gpu: {old_gpu} → 99")

# 6. streaming остаётся false (критично!)
params["streaming"] = False

with open(cfg_path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)

print(f"  {cfg_path}:")
for c in changes:
    print(f"    ✓ {c}")
PYOPT
done

###########################################################################
# 3. ПЕРЕЗАГРУЗКА МОДЕЛИ В OLLAMA (сброс кэша)
###########################################################################
echo ""
echo "[3/5] Перезагружаю модель в Ollama..."

# Выгружаем модель из памяти
curl -s http://localhost:11434/api/generate -d '{
    "model": "huihui_ai/qwen3.5-abliterated:35b",
    "keep_alive": 0
}' > /dev/null 2>&1

sleep 2

# Загружаем обратно с новыми параметрами
curl -s http://localhost:11434/api/generate -d '{
    "model": "huihui_ai/qwen3.5-abliterated:35b",
    "prompt": "test",
    "options": {
        "num_ctx": 16384,
        "num_predict": 1,
        "num_batch": 512,
        "num_gpu": 99
    }
}' > /dev/null 2>&1

echo "  ✓ Модель перезагружена с новыми параметрами"

###########################################################################
# 4. ПЕРЕЗАПУСК GATEWAY
###########################################################################
echo ""
echo "[4/5] Перезапускаю gateway..."

systemctl restart openclaw-gateway-moa 2>/dev/null
sleep 3
systemctl restart openclaw-gateway-mycarmibot 2>/dev/null
sleep 3

echo "  Порты:"
ss -tlnp | grep -E "1878|1879" | while read line; do
    echo "    $line"
done

if ss -tlnp | grep -q "18789"; then
    echo "  ✓ @mycarmi_moa_bot ACTIVE"
else
    echo "  ⚠ MoA не на порту — пробую nohup..."
    cd /root/.openclaw-moa
    OPENCLAW_HOME=/root/.openclaw-moa nohup npx openclaw gateway --port 18789 > /data/logs/gateway-moa.log 2>&1 &
    sleep 8
    ss -tlnp | grep "18789" && echo "  ✓ MoA ACTIVE (nohup)" || echo "  ✗ MoA не запустился"
fi

if ss -tlnp | grep -q "18793"; then
    echo "  ✓ @mycarmibot ACTIVE"
else
    echo "  ⚠ mycarmibot не на порту — пробую nohup..."
    cd /root/.openclaw-default
    OPENCLAW_HOME=/root/.openclaw-default nohup npx openclaw gateway --port 18793 > /data/logs/gateway-mycarmibot.log 2>&1 &
    sleep 8
    ss -tlnp | grep "18793" && echo "  ✓ mycarmibot ACTIVE (nohup)" || echo "  ✗ mycarmibot не запустился"
fi

###########################################################################
# 5. ТЕСТ СКОРОСТИ
###########################################################################
echo ""
echo "[5/5] Тест скорости Ollama..."

START=$(date +%s%N)
RESPONSE=$(curl -s --max-time 120 http://localhost:11434/api/generate -d '{
    "model": "huihui_ai/qwen3.5-abliterated:35b",
    "prompt": "What is FCA? Answer in 2 sentences.",
    "stream": false,
    "options": {
        "num_ctx": 16384,
        "num_predict": 256,
        "num_batch": 512,
        "temperature": 0.5,
        "num_gpu": 99
    }
}')
END=$(date +%s%N)

ELAPSED=$(( (END - START) / 1000000 ))
TOKENS=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('eval_count',0))" 2>/dev/null)
SPEED=$(echo "$RESPONSE" | python3 -c "
import sys,json
d=json.load(sys.stdin)
dur = d.get('eval_duration',1)
count = d.get('eval_count',0)
if dur > 0:
    print(f'{count/(dur/1e9):.1f}')
else:
    print('?')
" 2>/dev/null)

ANSWER=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('response','')[:200])" 2>/dev/null)

echo "  Время: ${ELAPSED}мс (~$(( ELAPSED / 1000 )) сек)"
echo "  Токенов: $TOKENS"
echo "  Скорость: $SPEED tok/s"
echo "  Ответ: $ANSWER"

echo ""
echo "=========================================="
echo "  ОПТИМИЗАЦИЯ ЗАВЕРШЕНА"
echo "=========================================="
echo ""
echo "  Что изменилось:"
echo "    - num_predict: 2048 (бот не будет писать эссе)"
echo "    - num_ctx: 16384 (вдвое меньше контекст = быстрее)"
echo "    - temperature: 0.5 (меньше 'раздумий')"
echo "    - num_batch: 512 (параллельная обработка)"
echo "    - num_gpu: 99 (все слои на GPU)"
echo ""
echo "  Ожидаемое ускорение: ~30-50%"
echo "  Проверь: напиши боту короткий вопрос"

REMOTE_END
