# Diagnostic Report — Ports & Services
> Сформирован: 2026-04-01 15:43 CEST
> Скрипт: scripts/diagnose-ports-and-services.sh

## Резюме

| Объект | Статус |
|--------|--------|
| Порт 18793 (@mycarmibot) | INACTIVE |
| Порт 8090 | INACTIVE |
| Порт 8091 | INACTIVE |
| hitl-dashboard.service | active |

## Полный вывод с GMKtec

```
=== PORT 18793 ===
STATUS: INACTIVE (port 18793 not listening)
SERVICE_FILE: openclaw-gateway-mycarmibot.service exists (inactive
unknown)

=== PORT 8090 ===
STATUS: INACTIVE

=== PORT 8091 ===
STATUS: INACTIVE

=== HITL DASHBOARD ===
SERVICE_STATUS: active
PID: 3778
CMDLINE: /data/hitl-dashboard/venv/bin/python /data/hitl-dashboard/app.py 
USER: root
WORKDIR: /data/hitl-dashboard
PORT: 8091
--- SERVICE FILE ---
# /etc/systemd/system/hitl-dashboard.service
[Unit]
Description=Banxe HITL Dashboard — KYC/AML Human Review
After=network.target clickhouse-server.service

[Service]
Type=simple
User=root
WorkingDirectory=/data/hitl-dashboard
Environment=HITL_PORT=8091
Environment=HITL_USER=banxe
Environment=HITL_PASS=
Environment=HITL_SECRET=
ExecStart=/data/hitl-dashboard/venv/bin/python /data/hitl-dashboard/app.py
Restart=always
RestartSec=5
MemoryMax=256M
CPUQuota=25%
NoNewPrivileges=true
StandardOutput=journal

=== ALL ACTIVE OPENCLAW SERVICES ===
  openclaw-gateway-guiyon.service loaded active running OpenClaw Gateway — GUIYON Legal (port 18794)
  openclaw-gateway-moa.service    loaded active running OpenClaw Gateway — @mycarmi_moa_bot (port 18789)

=== ALL PYTHON PROCESSES ===
root 1930 /usr/bin/python3 /opt/deep-search-server.py
root 1931 /usr/bin/python3 /usr/bin/fail2ban-server -xf start
root 1932 /usr/bin/python3 /data/guiyon-project/SCRIPTS/guiyon_api.py
root 1939 /opt/presidio-env/bin/python3 /opt/pii-proxy.py --serve --port 8089
root 1944 /usr/bin/python3 /usr/share/unattended-upgrades/unattended-upgrade-shutdown --wait-for-signal
root 2764 /usr/bin/python3 /data/guiyon-project/SCRIPTS/guiyon_dispatcher.py --watch --interval 30
root 3778 /data/hitl-dashboard/venv/bin/python /data/hitl-dashboard/app.py
banxe 4321 /usr/bin/python3 /usr/bin/orca
banxe 5210 /usr/bin/python3 /usr/share/system-config-printer/applet.py
```
