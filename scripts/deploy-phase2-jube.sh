#!/bin/bash
# deploy-phase2-jube.sh
#
# Phase 2: Jube — Transaction Monitoring + AML/Fraud Detection (AGPLv3)
# https://github.com/jube-home/aml-fraud-transaction-monitoring
#
# Что деплоится:
#   - PostgreSQL 17              (данные транзакций, кейсов, правил)
#   - Redis Stack                (кэш, поиск, порт 6379 + 8001)
#   - Jube WebAPI                (REST API, порт 5001)
#   - Jube Jobs                  (фоновые задачи: ML-обучение, callbacks, PEP-лоадер)
#
# Интеграция с Phase 1:
#   - Jube HTTP callback → Banxe Screener (/screen?name=...) для обогащения кейсов
#
# AGPLv3 — ТОЛЬКО internal deployment. Нельзя экспонировать как публичный SaaS.
#
# Запускать на Legion: bash scripts/deploy-phase2-jube.sh

set -e
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
JUBE_SRC="/data/banxe/jube-src"
JUBE_DATA="/data/banxe/jube-data"

echo "════════════════════════════════════════════"
echo "  Banxe Phase 2: Jube Transaction Monitoring"
echo "════════════════════════════════════════════"
echo ""

# ─────────────────────────────────────────────────────────
# ШАГ 1: Проверка предусловий
# ─────────────────────────────────────────────────────────
echo "[1/8] Проверка предусловий..."

ssh gmktec "docker --version && docker compose version" || {
    echo "  ОШИБКА: Docker не установлен!"
    exit 1
}

PORT_CHECK=$(ssh gmktec "ss -tlnp | grep -E ':5001|:5432|:6379' | head -5")
if [ -n "$PORT_CHECK" ]; then
    echo "  ПРЕДУПРЕЖДЕНИЕ — порты уже заняты:"
    echo "  $PORT_CHECK"
    echo "  Продолжаем (могут быть уже запущенные контейнеры)..."
fi

RAM_FREE=$(ssh gmktec "free -h | grep Mem | awk '{print \$7}'")
echo "  Docker: OK"
echo "  RAM available: $RAM_FREE"
echo "  Предусловия ✓"

# ─────────────────────────────────────────────────────────
# ШАГ 2: Клонируем репо Jube
# ─────────────────────────────────────────────────────────
echo ""
echo "[2/8] Клонируем jube-home/aml-fraud-transaction-monitoring..."

ssh gmktec "
if [ -d $JUBE_SRC/.git ]; then
    echo '  Репо уже есть, обновляем...'
    cd $JUBE_SRC && git pull --rebase origin master 2>&1 | tail -2
else
    echo '  Клонируем...'
    git clone --depth=1 https://github.com/jube-home/aml-fraud-transaction-monitoring $JUBE_SRC 2>&1 | tail -3
fi
echo '  Jube source: OK'
"

# ─────────────────────────────────────────────────────────
# ШАГ 3: Создаём .env с секретами
# ─────────────────────────────────────────────────────────
echo ""
echo "[3/8] Генерируем .env с секретами..."

ssh gmktec "
mkdir -p $JUBE_DATA
ENV_FILE=$JUBE_SRC/.env

# Генерируем секреты если .env не существует
if [ ! -f \"\$ENV_FILE\" ]; then
    JWT_KEY=\$(openssl rand -hex 32)
    PG_PASS=\$(openssl rand -base64 16 | tr -d '/+=')
    HASH_KEY=\$(openssl rand -hex 32)

    cat > \"\$ENV_FILE\" << ENVEOF
DockerComposePostgresPassword=\${PG_PASS}
DockerComposeJWTKey=\${JWT_KEY}
DockerComposePasswordHashingKey=\${HASH_KEY}
ENVEOF
    chmod 600 \"\$ENV_FILE\"
    echo '  .env создан с новыми секретами ✓'
else
    echo '  .env уже существует — используем существующие секреты ✓'
fi
"

# ─────────────────────────────────────────────────────────
# ШАГ 4: Создаём docker-compose.override.yml
# (меняем порты: 5432→15432 и 6379→16379 чтобы не конфликтовать)
# (data volumes → /data/banxe/jube-data)
# ─────────────────────────────────────────────────────────
echo ""
echo "[4/8] Создаём docker-compose.override.yml..."

ssh gmktec "cat > $JUBE_SRC/docker-compose.override.yml" << 'OVERRIDE_EOF'
# Banxe override — изолируем порты и тома от других сервисов
services:
  postgres:
    ports:
      - "127.0.0.1:15432:5432"
    volumes:
      - /data/banxe/jube-data/postgres:/var/lib/postgresql/data

  redis:
    ports:
      - "127.0.0.1:16379:6379"
      - "127.0.0.1:18001:8001"
    volumes:
      - /data/banxe/jube-data/redis:/data

  jube.webapi:
    ports:
      - "127.0.0.1:5001:5001"
    restart: unless-stopped

  jube.jobs:
    restart: unless-stopped
OVERRIDE_EOF

echo "  docker-compose.override.yml создан ✓"
echo "  Порты: PostgreSQL→15432, Redis→16379, Redis UI→18001, Jube API→5001"

# ─────────────────────────────────────────────────────────
# ШАГ 5: Docker build + compose up
# (сборка .NET займёт 5-15 минут при первом запуске)
# ─────────────────────────────────────────────────────────
echo ""
echo "[5/8] Docker build + compose up..."
echo "  ВНИМАНИЕ: первый build .NET займёт 5-15 минут..."
echo "  Следи за прогрессом:"
echo "  ssh gmktec 'cd $JUBE_SRC && docker compose logs -f jube.webapi'"
echo ""

ssh gmktec "
cd $JUBE_SRC
set -a && source .env && set +a

# Останавливаем если уже запущены
docker compose down --remove-orphans 2>/dev/null || true

# Build и запуск
echo '  Запуск docker compose build + up...'
docker compose up -d --build 2>&1 | tail -10
" || {
    echo "  ОШИБКА при docker compose up!"
    ssh gmktec "cd $JUBE_SRC && docker compose logs --tail=20 2>/dev/null"
    exit 1
}

# ─────────────────────────────────────────────────────────
# ШАГ 6: Ожидаем готовности Jube API
# ─────────────────────────────────────────────────────────
echo ""
echo "[6/8] Ожидаем готовности Jube API (максимум 10 минут)..."

MAX_WAIT=600
WAITED=0
INTERVAL=15

while [ $WAITED -lt $MAX_WAIT ]; do
    STATUS=$(ssh gmktec "curl -s -o /dev/null -w '%{http_code}' http://localhost:5001/api/Authentication/ByUserNamePassword 2>/dev/null || echo '000'")
    if [ "$STATUS" = "400" ] || [ "$STATUS" = "200" ] || [ "$STATUS" = "401" ]; then
        echo "  Jube API готов! HTTP $STATUS ✓"
        break
    fi

    BUILD_STATUS=$(ssh gmktec "docker compose -f $JUBE_SRC/docker-compose.yml -f $JUBE_SRC/docker-compose.override.yml ps --format 'table {{.Service}}\t{{.Status}}' 2>/dev/null | tail -5")
    echo "  Ждём... ($WAITED сек) HTTP=$STATUS"
    echo "    $BUILD_STATUS"

    sleep $INTERVAL
    WAITED=$((WAITED + INTERVAL))
done

if [ $WAITED -ge $MAX_WAIT ]; then
    echo "  ТАЙМАУТ! Проверь логи:"
    echo "  ssh gmktec 'cd $JUBE_SRC && docker compose logs --tail=30 jube.webapi'"
    exit 1
fi

# ─────────────────────────────────────────────────────────
# ШАГ 7: Первоначальная настройка через API
# ─────────────────────────────────────────────────────────
echo ""
echo "[7/8] Получаем JWT токен (Administrator/Administrator)..."

JWT=$(ssh gmktec "curl -s -X POST http://localhost:5001/api/Authentication/ByUserNamePassword \
    -H 'Content-Type: application/json' \
    -d '{\"UserName\":\"Administrator\",\"Password\":\"Administrator\"}' 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get(\"token\",\"\"))' 2>/dev/null")

if [ -z "$JWT" ] || [ "$JWT" = "None" ]; then
    echo "  JWT не получен — возможно, нужна смена пароля при первом входе"
    echo "  Открой http://[gmktec-ip]:5001 и войди как Administrator/Administrator"
    JWT="NOT_AVAILABLE"
else
    echo "  JWT получен ✓ (${#JWT} символов)"
fi

# Сохраняем JWT для использования ботом
ssh gmktec "echo '$JWT' > /data/banxe/jube-data/jwt.token && chmod 600 /data/banxe/jube-data/jwt.token"

# ─────────────────────────────────────────────────────────
# ШАГ 8: OpenClaw skill для Jube
# ─────────────────────────────────────────────────────────
echo ""
echo "[8/8] Создаём OpenClaw skill для Jube..."

SKILL_DIR="/home/mmber/.openclaw/workspace-moa/skills/jube-aml"
ssh gmktec "mkdir -p $SKILL_DIR"

ssh gmktec "cat > $SKILL_DIR/SKILL.md" << 'SKILL_EOF'
# Jube AML — Transaction Monitoring

## Что это
Jube — open-source система мониторинга транзакций (AGPLv3).
API: http://localhost:5001
Auth: JWT Bearer token

## Ключевые endpoint-ы

### Отправить транзакцию на оценку риска
```
POST http://localhost:5001/api/invoke/synchronous/{entityAnalysisModelGuid}
Authorization: Bearer {JWT}
Content-Type: application/json

{
  "accountId": "ACC123",
  "amount": 5000.00,
  "currencyCode": "GBP",
  "transactionDate": "2026-04-02T00:00:00Z",
  "responseElevation": 0
}
```

Ответ содержит: riskScore, activatedRules, caseCreated

### Получить список кейсов
```
GET http://localhost:5001/api/Case?page=1&pageSize=10
Authorization: Bearer {JWT}
```

### Получить JWT токен
```
POST http://localhost:5001/api/Authentication/ByUserNamePassword
{"UserName":"Administrator","Password":"Administrator"}
```

## Интеграция со Screener (Phase 1)
При получении высокого riskScore — обогащай через:
curl http://localhost:8085/screen?name={counterpartyName}

## Статусы кейсов
- Open: требует проверки
- Closed Positive: подтверждён AML/fraud
- Closed Negative: ложное срабатывание

## Когда использовать этот инструмент
- Пользователь спрашивает про мониторинг транзакций
- Нужно создать кейс вручную
- Нужно проверить риск-скор транзакции
SKILL_EOF

echo "  SKILL.md создан: $SKILL_DIR ✓"

# ─────────────────────────────────────────────────────────
# Финальная верификация
# ─────────────────────────────────────────────────────────
echo ""
echo "══════ Финальная проверка ══════"

CONTAINERS=$(ssh gmktec "docker compose -f $JUBE_SRC/docker-compose.yml -f $JUBE_SRC/docker-compose.override.yml ps --format 'table {{.Service}}\t{{.Status}}' 2>/dev/null")
echo "$CONTAINERS"

API_HEALTH=$(ssh gmktec "curl -s -o /dev/null -w 'HTTP %{http_code}' http://localhost:5001/api/Authentication/ByUserNamePassword 2>/dev/null")
echo ""
echo "  Jube API: $API_HEALTH"
echo "  Screener: $(ssh gmktec "curl -s http://localhost:8085/health 2>/dev/null")"
echo "  Watchman: $(ssh gmktec "curl -s 'http://localhost:8084/v2/search?name=test&limit=1' | python3 -c 'import sys,json; d=json.load(sys.stdin); print(\"UP, entities:\", len(d.get(\"entities\") or []))' 2>/dev/null")"

# ─────────────────────────────────────────────────────────
# Коммит
# ─────────────────────────────────────────────────────────
echo ""
echo "Коммит..."
cd "$REPO_DIR"
git add scripts/deploy-phase2-jube.sh
git commit -m "feat: Phase 2 — Jube transaction monitoring (AGPLv3, Docker)

- deploy-phase2-jube.sh: PostgreSQL 17 + Redis Stack + Jube WebAPI + Jobs
- Ports: Jube API→5001, PG→15432 (internal), Redis→16379 (internal)
- Data: /data/banxe/jube-data (1.7TB /data partition)
- OpenClaw skill: workspace-moa/skills/jube-aml/SKILL.md
- Integration: Jube cases → Screener /screen enrichment"
git pull --rebase origin main
git push origin main

echo ""
echo "════════════════════════════════════════════"
echo "  Phase 2: ГОТОВО"
echo "════════════════════════════════════════════"
echo ""
echo "  Jube UI:    http://[gmktec-ip]:5001"
echo "  Логин:      Administrator / Administrator"
echo "  ВАЖНО:      Смени пароль при первом входе!"
echo ""
echo "  Следующие шаги:"
echo "  1. Войди в UI и создай Entity Analysis Model для Banxe"
echo "  2. Настрой правила: сумма >10000 GBP → кейс"
echo "  3. Phase 3: PassportEye + DeepFace (KYC документы)"
echo ""
