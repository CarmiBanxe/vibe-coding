#!/bin/bash
# deploy-phase2-marble.sh
#
# Phase 2b: Marble — Case Management (Apache 2.0)
# https://github.com/checkmarble/marble-backend
#
# Что деплоится:
#   - Marble Backend  (Go API, порт 8080 → маппим на 5002)
#   - Marble Frontend (React UI, порт 3000 → маппим на 5003)
#   - PostgreSQL      (отдельная БД, порт 15433, internal only)
#   - Firebase Auth   (или local fallback)
#
# Интеграция с Phase 1 + 2a:
#   - Jube создаёт кейс → Marble API получает case через webhook
#   - Marble UI = MLRO/Compliance officer рабочий стол
#   - SAR decisions в Marble → audit trail в ClickHouse
#
# Apache 2.0 — можно использовать как SaaS.
#
# Запускать на Legion: bash scripts/deploy-phase2-marble.sh

set -e
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MARBLE_SRC="/data/banxe/marble-src"
MARBLE_DATA="/data/banxe/marble-data"
MARBLE_API_PORT=5002
MARBLE_UI_PORT=5003
MARBLE_PG_PORT=15433

echo "════════════════════════════════════════════"
echo "  Banxe Phase 2b: Marble Case Management"
echo "════════════════════════════════════════════"
echo ""

# ─────────────────────────────────────────────────────────
# ШАГ 1: Предусловия
# ─────────────────────────────────────────────────────────
echo "[1/7] Проверка предусловий..."

ssh gmktec "docker --version && docker compose version" || {
    echo "  ОШИБКА: Docker не установлен!"
    exit 1
}

# Проверяем что Jube уже запущен (Phase 2a)
JUBE_STATUS=$(ssh gmktec "curl -s -o /dev/null -w '%{http_code}' http://localhost:5001/api/Authentication/ByUserNamePassword 2>/dev/null || echo 000")
if [ "$JUBE_STATUS" = "000" ]; then
    echo "  ПРЕДУПРЕЖДЕНИЕ: Jube API (порт 5001) не отвечает"
    echo "  Запусти сначала: bash scripts/deploy-phase2-jube.sh"
    echo "  Продолжаем деплой Marble независимо..."
else
    echo "  Jube API: HTTP $JUBE_STATUS ✓"
fi

RAM_FREE=$(ssh gmktec "free -h | grep Mem | awk '{print \$7}'")
echo "  RAM available: $RAM_FREE"
echo "  Предусловия ✓"

# ─────────────────────────────────────────────────────────
# ШАГ 2: Клонируем Marble backend + frontend
# ─────────────────────────────────────────────────────────
echo ""
echo "[2/7] Клонируем checkmarble/marble-backend..."

ssh gmktec "
mkdir -p $MARBLE_DATA

if [ -d $MARBLE_SRC/backend/.git ]; then
    echo '  Backend: обновляем...'
    cd $MARBLE_SRC/backend && git pull --rebase origin main 2>&1 | tail -2
else
    echo '  Backend: клонируем...'
    mkdir -p $MARBLE_SRC
    git clone --depth=1 https://github.com/checkmarble/marble-backend $MARBLE_SRC/backend 2>&1 | tail -3
fi

if [ -d $MARBLE_SRC/frontend/.git ]; then
    echo '  Frontend: обновляем...'
    cd $MARBLE_SRC/frontend && git pull --rebase origin main 2>&1 | tail -2
else
    echo '  Frontend: клонируем...'
    git clone --depth=1 https://github.com/checkmarble/marble-frontend $MARBLE_SRC/frontend 2>&1 | tail -3
fi
echo '  Marble source: OK'
"

# ─────────────────────────────────────────────────────────
# ШАГ 3: .env файл
# ─────────────────────────────────────────────────────────
echo ""
echo "[3/7] Генерируем .env для Marble..."

ssh gmktec "
ENV_FILE=$MARBLE_SRC/backend/.env

if [ ! -f \"\$ENV_FILE\" ]; then
    PG_PASS=\$(openssl rand -base64 16 | tr -d '/+=')
    JWT_KEY=\$(openssl rand -hex 32)

    cat > \"\$ENV_FILE\" << ENVEOF
MARBLE_ENV=production
MARBLE_PG_HOST=marble-postgres
MARBLE_PG_PORT=5432
MARBLE_PG_DB=marble
MARBLE_PG_USER=marble
MARBLE_PG_PASSWORD=\${PG_PASS}
MARBLE_JWT_SIGNING_KEY=\${JWT_KEY}
MARBLE_LICENSE_KEY=
MARBLE_PORT=8080
MARBLE_AUTHENTICATION_CLIENT_LICENSE=
MARBLE_FIREBASE_PROJECT_ID=
MARBLE_FIREBASE_JSON_CREDENTIALS_PATH=
ENVEOF
    chmod 600 \"\$ENV_FILE\"
    echo '  .env создан ✓'
else
    echo '  .env уже существует ✓'
fi
"

# ─────────────────────────────────────────────────────────
# ШАГ 4: docker-compose для Marble
# ─────────────────────────────────────────────────────────
echo ""
echo "[4/7] Создаём docker-compose.marble.yml..."

ssh gmktec "cat > $MARBLE_SRC/docker-compose.marble.yml" << COMPOSE_EOF
# Marble Case Management — Banxe deployment
# Apache 2.0

services:
  marble-postgres:
    image: postgres:17-alpine
    container_name: banxe-marble-postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: marble
      POSTGRES_USER: marble
      POSTGRES_PASSWORD: \${MARBLE_PG_PASSWORD}
    ports:
      - "127.0.0.1:${MARBLE_PG_PORT}:5432"
    volumes:
      - ${MARBLE_DATA}/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U marble"]
      interval: 10s
      timeout: 5s
      retries: 5

  marble-backend:
    build:
      context: ${MARBLE_SRC}/backend
      dockerfile: Dockerfile
    container_name: banxe-marble-backend
    restart: unless-stopped
    depends_on:
      marble-postgres:
        condition: service_healthy
    env_file: ${MARBLE_SRC}/backend/.env
    environment:
      MARBLE_PG_HOST: marble-postgres
    ports:
      - "127.0.0.1:${MARBLE_API_PORT}:8080"
    networks:
      - marble-net

  marble-frontend:
    build:
      context: ${MARBLE_SRC}/frontend
      dockerfile: Dockerfile
      args:
        MARBLE_API_URL: http://localhost:${MARBLE_API_PORT}
    container_name: banxe-marble-frontend
    restart: unless-stopped
    depends_on:
      - marble-backend
    ports:
      - "0.0.0.0:${MARBLE_UI_PORT}:3000"
    networks:
      - marble-net

networks:
  marble-net:
    driver: bridge
COMPOSE_EOF

echo "  docker-compose.marble.yml создан ✓"

# ─────────────────────────────────────────────────────────
# ШАГ 5: Build + up
# ─────────────────────────────────────────────────────────
echo ""
echo "[5/7] Docker build + up Marble..."
echo "  ВНИМАНИЕ: Go build займёт 3-8 минут при первом запуске..."

ssh gmktec "
cd $MARBLE_SRC
source backend/.env
export \$(grep -v '^#' backend/.env | xargs)

docker compose -f docker-compose.marble.yml down --remove-orphans 2>/dev/null || true
docker compose -f docker-compose.marble.yml up -d --build 2>&1 | tail -15
" || {
    echo "  ОШИБКА при docker compose up!"
    ssh gmktec "cd $MARBLE_SRC && docker compose -f docker-compose.marble.yml logs --tail=20"
    exit 1
}

# ─────────────────────────────────────────────────────────
# ШАГ 6: Ожидаем готовности
# ─────────────────────────────────────────────────────────
echo ""
echo "[6/7] Ожидаем готовности Marble API (максимум 8 минут)..."

MAX_WAIT=480
WAITED=0
INTERVAL=15

while [ $WAITED -lt $MAX_WAIT ]; do
    STATUS=$(ssh gmktec "curl -s -o /dev/null -w '%{http_code}' http://localhost:${MARBLE_API_PORT}/health 2>/dev/null || echo 000")
    if [ "$STATUS" = "200" ] || [ "$STATUS" = "401" ]; then
        echo "  Marble API готов! HTTP $STATUS ✓"
        break
    fi
    echo "  Ждём... ($WAITED сек) HTTP=$STATUS"
    sleep $INTERVAL
    WAITED=$((WAITED + INTERVAL))
done

if [ $WAITED -ge $MAX_WAIT ]; then
    echo "  ТАЙМАУТ! Проверь логи:"
    echo "  ssh gmktec 'cd $MARBLE_SRC && docker compose -f docker-compose.marble.yml logs --tail=30'"
    exit 1
fi

# ─────────────────────────────────────────────────────────
# ШАГ 7: OpenClaw skill для Marble
# ─────────────────────────────────────────────────────────
echo ""
echo "[7/7] Создаём OpenClaw skill для Marble..."

SKILL_DIR="/home/mmber/.openclaw/workspace-moa/skills/marble-cases"
ssh gmktec "mkdir -p $SKILL_DIR"

ssh gmktec "cat > $SKILL_DIR/SKILL.md" << 'SKILL_EOF'
# Marble — Case Management

## Что это
Marble — open-source система управления кейсами для AML/compliance (Apache 2.0).
Backend API: http://localhost:5002
Frontend UI: http://localhost:5003
Auth: Bearer JWT

## Ключевые endpoint-ы

### Health check
```
GET http://localhost:5002/health
```

### Создать кейс вручную
```
POST http://localhost:5002/cases
Authorization: Bearer {JWT}
Content-Type: application/json
{
  "name": "Suspicious transaction ABC123",
  "inboxId": "{inbox_id}",
  "status": "open"
}
```

### Список открытых кейсов
```
GET http://localhost:5002/cases?status=open
Authorization: Bearer {JWT}
```

### Добавить комментарий к кейсу (MLRO decision)
```
POST http://localhost:5002/cases/{caseId}/comments
Authorization: Bearer {JWT}
{"comment": "SAR filed — case confirmed AML. Ref: SAR-2026-001"}
```

### Закрыть кейс
```
PATCH http://localhost:5002/cases/{caseId}
Authorization: Bearer {JWT}
{"status": "closed", "outcome": "positive"}
```

## Интеграция с Jube (Phase 2a)
Когда Jube создаёт high-risk кейс:
1. Jube webhook → POST /cases в Marble
2. MLRO видит кейс в Marble UI (http://localhost:5003)
3. MLRO принимает решение → комментарий в Marble
4. Decision → audit trail в ClickHouse

## Интеграция со Screener (Phase 1)
Обогащение кейса:
curl http://localhost:8085/screen?name={suspectName}
Результат добавлять как комментарий к кейсу.

## Когда использовать этот инструмент
- Пользователь спрашивает про открытые кейсы
- Нужно создать SAR кейс
- MLRO принял решение по транзакции
- Нужно проверить статус расследования
SKILL_EOF

echo "  SKILL.md создан: $SKILL_DIR ✓"

# ─────────────────────────────────────────────────────────
# Финальная верификация
# ─────────────────────────────────────────────────────────
echo ""
echo "══════ Финальная проверка ══════"

ssh gmktec "
JUBE_STATUS=\$(curl -s -o /dev/null -w 'HTTP %{http_code}' http://localhost:5001/api/Authentication/ByUserNamePassword 2>/dev/null)
MARBLE_STATUS=\$(curl -s -o /dev/null -w 'HTTP %{http_code}' http://localhost:${MARBLE_API_PORT}/health 2>/dev/null)
SCREENER_STATUS=\$(curl -s -o /dev/null -w 'HTTP %{http_code}' http://localhost:8085/health 2>/dev/null)

echo \"  Phase 1 — Screener:    \$SCREENER_STATUS\"
echo \"  Phase 2a — Jube API:   \$JUBE_STATUS\"
echo \"  Phase 2b — Marble API: \$MARBLE_STATUS\"
"

# Коммит
echo ""
echo "Коммит..."
cd "$REPO_DIR"
git add scripts/deploy-phase2-marble.sh
git commit -m "feat: Phase 2b — Marble case management (Apache 2.0, Docker)

- deploy-phase2-marble.sh: marble-backend (Go) + marble-frontend (React) + PostgreSQL 17
- Ports: Marble API→5002, Marble UI→5003, PG→15433 (internal)
- Data: /data/banxe/marble-data
- OpenClaw skill: workspace-moa/skills/marble-cases/SKILL.md
- Integration: Jube high-risk case → Marble case → MLRO decision → ClickHouse audit"
git pull --rebase origin main
git push origin main

echo ""
echo "════════════════════════════════════════════"
echo "  Phase 2b: ГОТОВО"
echo "════════════════════════════════════════════"
echo ""
echo "  Marble UI:  http://[gmktec-ip]:${MARBLE_UI_PORT}"
echo "  Marble API: http://[gmktec-ip]:${MARBLE_API_PORT}/health"
echo ""
echo "  Полный стек Phase 1 + 2:"
echo "  ┌─────────────────────────────────────────┐"
echo "  │ Screener (8085) → Watchman (8084)       │ Phase 1"
echo "  │ Jube TM  (5001) → SAR detection          │ Phase 2a"
echo "  │ Marble   (5002) → Case management        │ Phase 2b"
echo "  │ ClickHouse (9000) → FCA audit trail      │ всегда"
echo "  └─────────────────────────────────────────┘"
echo ""
echo "  Следующий шаг — Phase 3:"
echo "  PassportEye (MRZ) + DeepFace (liveness) → KYC documents"
echo ""
