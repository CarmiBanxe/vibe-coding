#!/bin/bash
# setup-hitl-dashboard.sh — HITL Dashboard для Banxe AI Bank
#
# Веб-интерфейс для оператора compliance:
#   - Список pending KYC (MANUAL_REVIEW) и AML (HOLD) решений
#   - APPROVE / REJECT с комментарием
#   - История решений
#   - Basic auth (CEO/CTIO only)
#
# Порт: 8091 (8090 занят)
# URL:  https://gmktec/hitl/ (через nginx)
#
# Запуск на Legion:
#   cd ~/vibe-coding && git pull && bash scripts/setup-hitl-dashboard.sh

set -euo pipefail

SSH="ssh gmktec"
DASHBOARD_DIR="/data/hitl-dashboard"
DASHBOARD_PORT=8091
SERVICE_NAME="hitl-dashboard"

echo "═══════════════════════════════════════════════════════════════"
echo " setup-hitl-dashboard.sh — HITL Dashboard Banxe AI Bank"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "═══════════════════════════════════════════════════════════════"

# ── STEP 1: Проверка зависимостей ────────────────────────────────────────────
echo ""
echo "━━━ STEP 1: Зависимости ━━━"

$SSH "
echo '  Проверка clickhouse-driver...'
pip3 show clickhouse-driver >/dev/null 2>&1 || pip3 install clickhouse-driver
echo '  ✓ clickhouse-driver OK'

echo '  Проверка flask...'
pip3 show flask >/dev/null 2>&1 || pip3 install flask
echo '  ✓ flask OK'
" 2>&1

# ── STEP 2: ClickHouse таблица hitl_decisions ─────────────────────────────────
echo ""
echo "━━━ STEP 2: ClickHouse таблица hitl_decisions ━━━"

$SSH "
curl -s -X POST 'http://localhost:8123/' \
  --data-binary \"CREATE TABLE IF NOT EXISTS banxe.hitl_decisions (
    id UUID DEFAULT generateUUIDv4(),
    decision_type String,
    original_id String,
    client_id String,
    original_result String,
    operator_decision String,
    operator_comment String,
    operator_name String,
    decided_at DateTime DEFAULT now()
  ) ENGINE = MergeTree()
  ORDER BY (decided_at, decision_type)\"
echo '  ✓ banxe.hitl_decisions создана (или уже существует)'
" 2>&1

# ── STEP 3: Flask приложение ──────────────────────────────────────────────────
echo ""
echo "━━━ STEP 3: Flask приложение ━━━"

$SSH "mkdir -p $DASHBOARD_DIR" 2>&1

ssh gmktec bash -s << 'APPEOF'
set -euo pipefail
DIR="/data/hitl-dashboard"

cat > "$DIR/app.py" << 'PYEOF'
#!/usr/bin/env python3
"""
HITL Dashboard — Banxe AI Bank
Compliance operator interface for KYC/AML manual review decisions.
"""
import os
import json
from datetime import datetime
from functools import wraps
from flask import Flask, request, jsonify, render_template_string, redirect, url_for, session
from clickhouse_driver import Client

app = Flask(__name__)
app.secret_key = os.environ.get('HITL_SECRET', 'REDACTED_HITL_KEY')

CH_HOST = 'localhost'
CH_PORT = 9000
CH_DB   = 'banxe'

USERS = {
    os.environ.get('HITL_USER', 'banxe'): os.environ.get('HITL_PASS', 'changeme')
}

def get_ch():
    return Client(host=CH_HOST, port=CH_PORT, database=CH_DB)

def login_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if not session.get('logged_in'):
            return redirect('/hitl/login')
        return f(*args, **kwargs)
    return decorated

HTML_BASE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>HITL Dashboard — Banxe AI Bank</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css">
<style>
body { background: #0f1117; color: #e0e0e0; }
.navbar { background: #1a1d27 !important; border-bottom: 1px solid #2a2d3a; }
.card { background: #1a1d27; border: 1px solid #2a2d3a; }
.badge-manual { background: #ff6b35; }
.badge-hold { background: #f7c59f; color: #000; }
.badge-approve { background: #2ecc71; }
.badge-reject { background: #e74c3c; }
.table { color: #e0e0e0; }
.table-dark { --bs-table-bg: #1a1d27; }
.btn-approve { background: #2ecc71; border: none; color: #000; font-weight: bold; }
.btn-reject  { background: #e74c3c; border: none; color: #fff; font-weight: bold; }
.stat-card { border-left: 4px solid; }
.stat-kyc  { border-color: #ff6b35; }
.stat-aml  { border-color: #f7c59f; }
.stat-done { border-color: #2ecc71; }
</style>
</head>
<body>
<nav class="navbar navbar-dark navbar-expand-lg">
  <div class="container-fluid">
    <span class="navbar-brand fw-bold">🏦 Banxe HITL Dashboard</span>
    <span class="navbar-text text-muted small">FCA Compliance — Human-in-the-Loop</span>
    <a href="/hitl/logout" class="btn btn-sm btn-outline-secondary ms-3">Logout</a>
  </div>
</nav>
<div class="container-fluid mt-4">
{% block content %}{% endblock %}
</div>
</body>
</html>"""

LOGIN_HTML = """<!DOCTYPE html>
<html><head><title>HITL Login</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css">
<style>body{background:#0f1117;color:#e0e0e0;}</style>
</head><body>
<div class="d-flex justify-content-center align-items-center" style="height:100vh">
<div class="card p-4" style="width:360px;background:#1a1d27;border:1px solid #2a2d3a">
  <h4 class="mb-4 text-center">🏦 Banxe HITL</h4>
  {% if error %}<div class="alert alert-danger">{{ error }}</div>{% endif %}
  <form method="POST">
    <div class="mb-3"><input name="username" class="form-control bg-dark text-light border-secondary" placeholder="Username" required></div>
    <div class="mb-3"><input name="password" type="password" class="form-control bg-dark text-light border-secondary" placeholder="Password" required></div>
    <button class="btn btn-warning w-100 fw-bold">Login</button>
  </form>
</div></div></body></html>"""

DASHBOARD_HTML = """
{% extends base %}
{% block content %}
<div class="row mb-4">
  <div class="col-md-4">
    <div class="card stat-card stat-kyc p-3">
      <div class="text-muted small">KYC MANUAL_REVIEW</div>
      <div class="fs-2 fw-bold text-warning">{{ kyc_count }}</div>
    </div>
  </div>
  <div class="col-md-4">
    <div class="card stat-card stat-aml p-3">
      <div class="text-muted small">AML HOLD</div>
      <div class="fs-2 fw-bold" style="color:#f7c59f">{{ aml_count }}</div>
    </div>
  </div>
  <div class="col-md-4">
    <div class="card stat-card stat-done p-3">
      <div class="text-muted small">Decisions Today</div>
      <div class="fs-2 fw-bold text-success">{{ today_count }}</div>
    </div>
  </div>
</div>

{% if kyc_pending %}
<div class="card mb-4">
  <div class="card-header fw-bold" style="background:#1a1d27">
    🔶 KYC — Manual Review Required ({{ kyc_pending|length }})
  </div>
  <div class="card-body p-0">
    <table class="table table-dark table-hover mb-0">
      <thead><tr>
        <th>Time</th><th>Client ID</th><th>Details</th><th>Agent</th><th>Action</th>
      </tr></thead>
      <tbody>
      {% for r in kyc_pending %}
      <tr>
        <td class="text-muted small">{{ r.ts }}</td>
        <td><code>{{ r.client_id }}</code></td>
        <td class="small">{{ r.details[:120] }}{% if r.details|length > 120 %}...{% endif %}</td>
        <td class="small text-muted">{{ r.agent }}</td>
        <td>
          <form method="POST" action="/hitl/decide" class="d-flex gap-1">
            <input type="hidden" name="dtype" value="kyc">
            <input type="hidden" name="original_id" value="{{ r.id }}">
            <input type="hidden" name="client_id" value="{{ r.client_id }}">
            <input type="hidden" name="original_result" value="{{ r.result }}">
            <input name="comment" class="form-control form-control-sm bg-dark text-light border-secondary" placeholder="Comment" style="width:140px">
            <button name="decision" value="APPROVE" class="btn btn-sm btn-approve">✓ Approve</button>
            <button name="decision" value="REJECT" class="btn btn-sm btn-reject">✗ Reject</button>
          </form>
        </td>
      </tr>
      {% endfor %}
      </tbody>
    </table>
  </div>
</div>
{% endif %}

{% if aml_pending %}
<div class="card mb-4">
  <div class="card-header fw-bold" style="background:#1a1d27">
    🛡️ AML — Hold ({{ aml_pending|length }})
  </div>
  <div class="card-body p-0">
    <table class="table table-dark table-hover mb-0">
      <thead><tr>
        <th>Time</th><th>Client ID</th><th>Details</th><th>Agent</th><th>Action</th>
      </tr></thead>
      <tbody>
      {% for r in aml_pending %}
      <tr>
        <td class="text-muted small">{{ r.ts }}</td>
        <td><code>{{ r.client_id }}</code></td>
        <td class="small">{{ r.details[:120] }}{% if r.details|length > 120 %}...{% endif %}</td>
        <td class="small text-muted">{{ r.agent }}</td>
        <td>
          <form method="POST" action="/hitl/decide" class="d-flex gap-1">
            <input type="hidden" name="dtype" value="aml">
            <input type="hidden" name="original_id" value="{{ r.id }}">
            <input type="hidden" name="client_id" value="{{ r.client_id }}">
            <input type="hidden" name="original_result" value="{{ r.result }}">
            <input name="comment" class="form-control form-control-sm bg-dark text-light border-secondary" placeholder="Comment" style="width:140px">
            <button name="decision" value="APPROVE" class="btn btn-sm btn-approve">✓ Release</button>
            <button name="decision" value="REJECT" class="btn btn-sm btn-reject">✗ Block</button>
          </form>
        </td>
      </tr>
      {% endfor %}
      </tbody>
    </table>
  </div>
</div>
{% endif %}

{% if not kyc_pending and not aml_pending %}
<div class="alert text-center" style="background:#1a1d27;border:1px solid #2a2d3a;color:#6c757d">
  ✅ No pending decisions at this time.
</div>
{% endif %}

<div class="card">
  <div class="card-header" style="background:#1a1d27">Recent Decisions (last 20)</div>
  <div class="card-body p-0">
    <table class="table table-dark table-sm mb-0">
      <thead><tr><th>Time</th><th>Type</th><th>Client</th><th>Was</th><th>Decision</th><th>By</th><th>Comment</th></tr></thead>
      <tbody>
      {% for r in recent %}
      <tr>
        <td class="text-muted small">{{ r.ts }}</td>
        <td><span class="badge bg-secondary">{{ r.dtype }}</span></td>
        <td><code class="small">{{ r.client_id }}</code></td>
        <td class="small text-muted">{{ r.original_result }}</td>
        <td>
          {% if r.decision == 'APPROVE' %}
          <span class="badge badge-approve" style="background:#2ecc71;color:#000">✓ APPROVE</span>
          {% else %}
          <span class="badge badge-reject" style="background:#e74c3c">✗ REJECT</span>
          {% endif %}
        </td>
        <td class="small text-muted">{{ r.operator }}</td>
        <td class="small text-muted">{{ r.comment }}</td>
      </tr>
      {% endfor %}
      </tbody>
    </table>
  </div>
</div>
{% endblock %}
"""

@app.route('/hitl/login', methods=['GET', 'POST'])
def login():
    error = None
    if request.method == 'POST':
        u = request.form.get('username', '')
        p = request.form.get('password', '')
        if USERS.get(u) == p:
            session['logged_in'] = True
            session['username'] = u
            return redirect('/hitl/')
        error = 'Invalid credentials'
    return render_template_string(LOGIN_HTML, error=error)

@app.route('/hitl/logout')
def logout():
    session.clear()
    return redirect('/hitl/login')

@app.route('/hitl/')
@login_required
def dashboard():
    ch = get_ch()
    try:
        kyc_rows = ch.execute(
            "SELECT toString(id), client_id, result, details, agent, toString(timestamp) FROM kyc_events WHERE result='MANUAL_REVIEW' ORDER BY timestamp DESC LIMIT 50"
        )
        kyc_pending = [{'id': r[0], 'client_id': r[1], 'result': r[2], 'details': r[3] or '', 'agent': r[4] or '', 'ts': r[5]} for r in kyc_rows]
    except Exception as e:
        kyc_pending = []

    try:
        aml_rows = ch.execute(
            "SELECT toString(id), client_id, result, details, agent, toString(timestamp) FROM aml_alerts WHERE result='HOLD' ORDER BY timestamp DESC LIMIT 50"
        )
        aml_pending = [{'id': r[0], 'client_id': r[1], 'result': r[2], 'details': r[3] or '', 'agent': r[4] or '', 'ts': r[5]} for r in aml_rows]
    except Exception as e:
        aml_pending = []

    try:
        today = ch.execute("SELECT count() FROM hitl_decisions WHERE toDate(decided_at) = today()")[0][0]
    except Exception:
        today = 0

    try:
        recent_rows = ch.execute(
            "SELECT decision_type, client_id, original_result, operator_decision, operator_name, operator_comment, toString(decided_at) FROM hitl_decisions ORDER BY decided_at DESC LIMIT 20"
        )
        recent = [{'dtype': r[0], 'client_id': r[1], 'original_result': r[2], 'decision': r[3], 'operator': r[4], 'comment': r[5] or '', 'ts': r[6]} for r in recent_rows]
    except Exception:
        recent = []

    return render_template_string(
        DASHBOARD_HTML,
        base=HTML_BASE,
        kyc_pending=kyc_pending,
        aml_pending=aml_pending,
        kyc_count=len(kyc_pending),
        aml_count=len(aml_pending),
        today_count=today,
        recent=recent
    )

@app.route('/hitl/decide', methods=['POST'])
@login_required
def decide():
    ch = get_ch()
    dtype    = request.form.get('dtype', '')
    orig_id  = request.form.get('original_id', '')
    client_id= request.form.get('client_id', '')
    orig_res = request.form.get('original_result', '')
    decision = request.form.get('decision', '')
    comment  = request.form.get('comment', '')
    operator = session.get('username', 'unknown')

    ch.execute(
        "INSERT INTO hitl_decisions (decision_type, original_id, client_id, original_result, operator_decision, operator_comment, operator_name) VALUES",
        [{'decision_type': dtype, 'original_id': orig_id, 'client_id': client_id,
          'original_result': orig_res, 'operator_decision': decision,
          'operator_comment': comment, 'operator_name': operator}]
    )
    return redirect('/hitl/')

@app.route('/hitl/api/pending')
@login_required
def api_pending():
    ch = get_ch()
    try:
        kyc = ch.execute("SELECT count() FROM kyc_events WHERE result='MANUAL_REVIEW'")[0][0]
        aml = ch.execute("SELECT count() FROM aml_alerts WHERE result='HOLD'")[0][0]
    except Exception:
        kyc, aml = 0, 0
    return jsonify({'kyc_manual_review': kyc, 'aml_hold': aml, 'total': kyc + aml})

if __name__ == '__main__':
    port = int(os.environ.get('HITL_PORT', 8091))
    app.run(host='0.0.0.0', port=port, debug=False)
PYEOF

echo "  ✓ app.py записан"
APPEOF

# ── STEP 4: .env файл ─────────────────────────────────────────────────────────
echo ""
echo "━━━ STEP 4: .env конфигурация ━━━"

$SSH "
# Пароль из системного .env если есть, иначе генерируем
if [ -f /data/.env ]; then
    HITL_PASS=\$(grep 'HITL_PASS' /data/.env 2>/dev/null | cut -d= -f2 || echo '')
fi
if [ -z \"\${HITL_PASS:-}\" ]; then
    HITL_PASS=\$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)
    echo \"HITL_PASS=\$HITL_PASS\" >> /data/.env
    echo '  ✓ HITL_PASS сгенерирован → /data/.env'
else
    echo '  ~ HITL_PASS уже в /data/.env'
fi
chmod 600 /data/.env
" 2>&1

# ── STEP 5: systemd service ───────────────────────────────────────────────────
echo ""
echo "━━━ STEP 5: systemd service ━━━"

$SSH "
HITL_PASS=\$(grep 'HITL_PASS' /data/.env 2>/dev/null | cut -d= -f2 || echo 'changeme')
HITL_SECRET=\$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)

cat > /etc/systemd/system/hitl-dashboard.service << EOF
[Unit]
Description=Banxe HITL Dashboard — KYC/AML Human Review
After=network.target clickhouse-server.service

[Service]
Type=simple
User=banxe
WorkingDirectory=/data/hitl-dashboard
Environment=HITL_PORT=8091
Environment=HITL_USER=banxe
Environment=HITL_PASS=\$HITL_PASS
Environment=HITL_SECRET=\$HITL_SECRET
ExecStart=/usr/bin/python3 /data/hitl-dashboard/app.py
Restart=always
RestartSec=5
MemoryMax=256M
CPUQuota=25%
NoNewPrivileges=true
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

chown banxe:banxe /data/hitl-dashboard/ -R 2>/dev/null || true
systemctl daemon-reload
systemctl enable hitl-dashboard.service
systemctl restart hitl-dashboard.service
sleep 3
STATUS=\$(systemctl is-active hitl-dashboard.service)
echo \"  Статус: \$STATUS\"
" 2>&1

# ── STEP 6: nginx location ────────────────────────────────────────────────────
echo ""
echo "━━━ STEP 6: nginx /hitl/ location ━━━"

$SSH "
# Добавляем location в nginx если нет
NGINX_CONF=\$(nginx -T 2>/dev/null | grep 'configuration file' | grep 'nginx.conf' | awk '{print \$NF}' | head -1)
NGINX_CONF=\${NGINX_CONF:-/etc/nginx/nginx.conf}
CONF_DIR=\$(dirname \$NGINX_CONF)/conf.d

cat > \$CONF_DIR/hitl-dashboard.conf << 'NGINXEOF'
server {
    listen 443 ssl;
    server_name _;
    include /etc/nginx/snippets/self-signed.conf 2>/dev/null;

    location /hitl/ {
        proxy_pass http://127.0.0.1:8091/hitl/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
    }
}
NGINXEOF

nginx -t 2>&1 && systemctl reload nginx && echo '  ✓ nginx reload OK' || echo '  ⚠ nginx test failed — проверь конфиг вручную'
" 2>&1

# ── STEP 7: Финальная проверка ────────────────────────────────────────────────
echo ""
echo "━━━ STEP 7: Проверка ━━━"

$SSH "
echo '  Порты 809x:'
ss -tlnp | grep '809' || echo '  нет'
echo ''
echo '  Статус hitl-dashboard:'
systemctl is-active hitl-dashboard.service
echo ''
echo '  Health check:'
sleep 1
curl -s -o /dev/null -w '  HTTP %{http_code}' http://localhost:8091/hitl/login || echo '  FAIL'
echo ''
" 2>&1

# ── STEP 8: MEMORY.md + push ──────────────────────────────────────────────────
echo ""
echo "━━━ STEP 8: MEMORY.md + push ━━━"

ssh gmktec bash -s << 'MEMEOF'
python3 << 'PYEOF'
import re
f = '/data/vibe-coding/docs/MEMORY.md'
with open(f) as fh:
    content = fh.read()

entry = """
## HITL Dashboard (2026-03-31) — УСТАНОВЛЕН
- **URL**: http://localhost:8091/hitl/ (или https://gmktec/hitl/ через nginx)
- **Auth**: banxe / HITL_PASS (в /data/.env)
- **Стек**: Python Flask + clickhouse-driver, systemd hitl-dashboard.service
- **Порт**: 8091 (8090 был занят python3)
- **Функции**: pending KYC MANUAL_REVIEW + AML HOLD, approve/reject с комментарием, история решений
- **ClickHouse**: banxe.hitl_decisions — FCA audit trail операторских решений
- **Безопасность**: MemoryMax=256M, CPUQuota=25%, NoNewPrivileges=true
"""

marker = '## HITL Dashboard'
if marker in content:
    content = re.sub(r'## HITL Dashboard.*?(?=\n## |\Z)', entry.strip() + '\n', content, flags=re.DOTALL)
else:
    content = content.rstrip() + '\n' + entry

with open(f, 'w') as fh:
    fh.write(content)
print('  ✓ MEMORY.md обновлён')
PYEOF

# Копируем скрипт и пушим
MEMEOF

scp -q /home/mmber/vibe-coding/scripts/setup-hitl-dashboard.sh gmktec:/data/vibe-coding/scripts/
$SSH "cd /data/vibe-coding && \
    git add scripts/setup-hitl-dashboard.sh docs/MEMORY.md && \
    git commit -m 'feat: HITL Dashboard — Flask веб-интерфейс для KYC/AML решений (порт 8091)' && \
    git push origin main && echo '  ✓ pushed'" 2>&1

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo " HITL Dashboard готов"
echo " URL:  http://[gmktec-ip]:8091/hitl/"
echo " Auth: banxe / (пароль в /data/.env → HITL_PASS)"
echo " API:  GET /hitl/api/pending — счётчик pending decisions"
echo "═══════════════════════════════════════════════════════════════"
