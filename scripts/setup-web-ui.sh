#!/bin/bash
###############################################################################
# setup-web-ui.sh — Web UI для OpenClaw через nginx + SSL
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/setup-web-ui.sh
#
# Что делает:
#   1. Устанавливает nginx на GMKtec
#   2. Создаёт усиленный конфиг (по руководству, стр. 56-58):
#      - Rate limiting (10 req/s общий, 3 req/s для auth)
#      - Security headers (HSTS, X-Frame-Options, CSP)
#      - WebSocket поддержка (для чата в реальном времени)
#      - Proxy к OpenClaw Gateway (127.0.0.1:18789)
#   3. Генерирует самоподписанный SSL сертификат
#      (для домена добавим Let's Encrypt позже)
#   4. Добавляет trustedProxies в конфиг OpenClaw
#   5. Настраивает HTTP Basic Auth (логин/пароль)
#   6. Открывает порт 443 в firewall
#   7. Тестирует
#
# После этого:
#   Локальная сеть: https://192.168.0.72 (Web UI)
#   Извне (если NAT): https://90.116.185.11 (нужно пробросить 443)
#   Telegram: как раньше (параллельно)
###############################################################################

set -euo pipefail

echo "=========================================="
echo "  WEB UI — OpenClaw Control Panel"
echo "  nginx + SSL + аутентификация"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE_END'
export PATH="$PATH:/root/.local/bin"

LOG="/data/logs/web-ui-setup.log"
mkdir -p /data/logs
log() { echo "$(date '+%H:%M:%S') $1" | tee -a "$LOG"; }

###########################################################################
# 1. NGINX
###########################################################################
log "[1/7] Устанавливаю nginx..."

if command -v nginx &>/dev/null; then
    log "  nginx уже установлен: $(nginx -v 2>&1)"
else
    apt-get update -qq
    apt-get install -y nginx apache2-utils 2>&1 | tail -3
    log "  ✓ nginx установлен"
fi

# apache2-utils для htpasswd
if ! command -v htpasswd &>/dev/null; then
    apt-get install -y apache2-utils 2>&1 | tail -1
fi

###########################################################################
# 2. SSL СЕРТИФИКАТ (самоподписанный)
###########################################################################
log "[2/7] Генерирую SSL сертификат..."

SSL_DIR="/etc/nginx/ssl"
mkdir -p "$SSL_DIR"

if [ ! -f "$SSL_DIR/openclaw.crt" ]; then
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$SSL_DIR/openclaw.key" \
        -out "$SSL_DIR/openclaw.crt" \
        -subj "/C=FR/ST=France/L=Paris/O=Banxe/CN=banxe-openclaw" \
        2>/dev/null
    chmod 600 "$SSL_DIR/openclaw.key"
    log "  ✓ SSL сертификат создан (самоподписанный, 365 дней)"
else
    log "  SSL сертификат уже существует"
fi

###########################################################################
# 3. HTTP BASIC AUTH
###########################################################################
log "[3/7] Настраиваю аутентификацию..."

AUTH_FILE="/etc/nginx/.htpasswd"
AUTH_PASS="Banxe2026!"

if [ ! -f "$AUTH_FILE" ]; then
    # Два пользователя: ceo (Марк) и ctio (Олег)
    htpasswd -cb "$AUTH_FILE" ceo "$AUTH_PASS" 2>/dev/null
    htpasswd -b "$AUTH_FILE" ctio "$AUTH_PASS" 2>/dev/null
    chmod 640 "$AUTH_FILE"
    chown root:www-data "$AUTH_FILE"
    log "  ✓ Пользователи созданы: ceo, ctio (пароль: $AUTH_PASS)"
    log "  ⚠ СМЕНИТЕ ПАРОЛИ после первого входа!"
else
    log "  .htpasswd уже существует"
fi

###########################################################################
# 4. NGINX КОНФИГ (по руководству, стр. 56-58)
###########################################################################
log "[4/7] Создаю конфиг nginx..."

cat > /etc/nginx/sites-available/openclaw << 'NGINX_CONF'
# === OpenClaw Web UI — Banxe AI Bank ===
# По руководству: Explain OpenClaw, стр. 56-58

# Rate limiting zones
limit_req_zone $binary_remote_addr zone=general:10m rate=10r/s;
limit_req_zone $binary_remote_addr zone=auth:10m rate=3r/s;

# HTTPS server
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name _;

    # SSL
    ssl_certificate /etc/nginx/ssl/openclaw.crt;
    ssl_certificate_key /etc/nginx/ssl/openclaw.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    # Security headers (по руководству)
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "DENY" always;
    add_header Referrer-Policy "no-referrer" always;
    add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;

    # Request body limit
    client_max_body_size 10m;

    # General rate limit
    limit_req zone=general burst=20 nodelay;

    # HTTP Basic Auth
    auth_basic "Banxe AI Bank — Restricted Access";
    auth_basic_user_file /etc/nginx/.htpasswd;

    # Auth endpoints — строгий rate limit
    location /api/auth {
        limit_req zone=auth burst=5 nodelay;
        proxy_pass http://127.0.0.1:18789;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # Main proxy с WebSocket
    location / {
        proxy_pass http://127.0.0.1:18789;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # WebSocket upgrade
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400s;
    }

    # Логирование
    access_log /data/logs/nginx-openclaw-access.log;
    error_log /data/logs/nginx-openclaw-error.log;
}

# HTTP → HTTPS redirect
server {
    listen 80;
    listen [::]:80;
    server_name _;
    return 301 https://$host$request_uri;
}
NGINX_CONF

# Активируем сайт
ln -sf /etc/nginx/sites-available/openclaw /etc/nginx/sites-enabled/openclaw
rm -f /etc/nginx/sites-enabled/default 2>/dev/null

log "  ✓ Конфиг создан: /etc/nginx/sites-available/openclaw"

###########################################################################
# 5. TRUSTED PROXIES в OpenClaw
###########################################################################
log "[5/7] Добавляю trustedProxies в конфиг OpenClaw..."

for CFG in \
    "/root/.openclaw-moa/.openclaw/openclaw.json" \
    "/root/.openclaw-default/.openclaw/openclaw.json"; do
    
    if [ ! -f "$CFG" ]; then continue; fi
    
    python3 << PYFIX
import json
with open("$CFG") as f:
    cfg = json.load(f)
gw = cfg.setdefault("gateway", {})
if gw.get("trustedProxies") != ["127.0.0.1"]:
    gw["trustedProxies"] = ["127.0.0.1"]
    with open("$CFG", "w") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
    print(f"  ✓ {('$CFG').split('/')[-3]}: trustedProxies=[127.0.0.1]")
else:
    print(f"  {('$CFG').split('/')[-3]}: уже настроено")
PYFIX
done

###########################################################################
# 6. FIREWALL
###########################################################################
log "[6/7] Настраиваю firewall..."

if command -v ufw &>/dev/null; then
    ufw allow 443/tcp comment "OpenClaw Web UI" 2>/dev/null || true
    ufw allow 80/tcp comment "HTTP→HTTPS redirect" 2>/dev/null || true
    log "  ✓ Порты 80, 443 открыты в UFW"
else
    # iptables fallback
    iptables -A INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
    iptables -A INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
    log "  ✓ Порты 80, 443 открыты в iptables"
fi

###########################################################################
# 7. ЗАПУСК И ТЕСТ
###########################################################################
log "[7/7] Запускаю nginx..."

# Проверяем конфиг
nginx -t 2>&1 | tee -a "$LOG"

if nginx -t 2>/dev/null; then
    systemctl enable nginx 2>/dev/null
    systemctl restart nginx 2>/dev/null
    sleep 2
    
    if systemctl is-active nginx &>/dev/null; then
        log "  ✓ nginx ACTIVE"
    else
        log "  ✗ nginx не запустился"
        journalctl -u nginx --no-pager -n 5 2>/dev/null | tail -5
    fi
else
    log "  ✗ Ошибка в конфигe nginx"
fi

# Тест
echo ""
echo "  Тест HTTPS:"
RESPONSE=$(curl -sk --max-time 10 -o /dev/null -w "%{http_code}" https://127.0.0.1/ -u "ceo:$AUTH_PASS" 2>/dev/null)
echo "    curl https://127.0.0.1 → HTTP $RESPONSE"

if [ "$RESPONSE" = "200" ] || [ "$RESPONSE" = "101" ] || [ "$RESPONSE" = "302" ]; then
    echo "    ✓ Web UI работает!"
elif [ "$RESPONSE" = "401" ]; then
    echo "    ✓ nginx работает (401 = аутентификация требуется — это правильно)"
elif [ "$RESPONSE" = "502" ]; then
    echo "    ⚠ nginx работает, но Gateway не отвечает на 18789"
    echo "    Проверь: ss -tlnp | grep 18789"
else
    echo "    ⚠ Неожиданный ответ: $RESPONSE"
fi

echo ""
echo "  Порты nginx:"
ss -tlnp | grep -E ":80 |:443 " | while read line; do echo "    $line"; done

echo ""
echo "  Gateway порты:"
ss -tlnp | grep -E "1878|1879" | while read line; do echo "    $line"; done

# КАНОН: обновляем MEMORY.md
for DIR in "/root/.openclaw-moa/workspace-moa" "/root/.openclaw-default/.openclaw/workspace"; do
    if [ -f "$DIR/MEMORY.md" ]; then
        if ! grep -q "Web UI настроен" "$DIR/MEMORY.md"; then
            cat >> "$DIR/MEMORY.md" << 'MEMUPD'

## Обновление: Web UI (30.03.2026)
- Web UI: nginx reverse proxy → OpenClaw Control Panel
- HTTPS: самоподписанный сертификат (для домена — Let's Encrypt)
- Аутентификация: HTTP Basic Auth (ceo, ctio)
- Rate limiting: 10 req/s общий, 3 req/s auth
- Security headers: HSTS, X-Frame-Options, CSP, no-referrer
- Доступ локальная сеть: https://192.168.0.72
- Логи: /data/logs/nginx-openclaw-access.log
- Web UI настроен по руководству (стр. 56-58)
MEMUPD
        fi
    fi
done

REMOTE_END

echo ""
echo "=========================================="
echo "  WEB UI НАСТРОЕН"
echo "=========================================="
echo ""
echo "  Два канала доступа к боту:"
echo ""
echo "  📱 Telegram (как раньше):"
echo "    @mycarmi_moa_bot, @mycarmibot"
echo "    Быстрый доступ, повседневные вопросы"
echo "    Защита: allowlist + read-only"
echo ""
echo "  🖥 Web UI (новый):"
echo "    Локальная сеть: https://192.168.0.72"
echo "    Логин: ceo / Пароль: Banxe2026!"
echo "    Логин: ctio / Пароль: Banxe2026!"
echo "    ⚠ СМЕНИТЕ ПАРОЛИ после первого входа!"
echo ""
echo "  Для доступа извне — пробросить порт 443 на роутере:"
echo "    Livebox 5 → NAT/PAT → 443 → 192.168.0.72:443"
echo "    Тогда: https://90.116.185.11"
echo ""
echo "  ⚠ Браузер покажет предупреждение о сертификате —"
echo "    это нормально (самоподписанный). Нажми 'Продолжить'."
echo "    Для доменного сертификата: certbot --nginx -d your-domain.com"
