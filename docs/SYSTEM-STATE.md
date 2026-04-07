# SYSTEM-STATE — GMKtec EVO-X2
> Автоматически обновляется каждые 5 минут
> Последнее сканирование: 2026-04-07 13:15 CEST
> Источник: ctio-watcher.sh v2 (cron)

## Назначение
Бот и агенты читают этот файл для актуального состояния сервера.
Все данные собраны автоматически. Бот НЕ имеет прав на изменение сервера.
Любые изменения (Олег, CEO, или автоматика) фиксируются здесь.

---

## Ресурсы
- RAM: 11Gi / 30Gi (free: 1.6Gi)
- Load: 2.56 2.48 2.46
- GPU VRAM used: 58.5 GB

## Диски
| Устройство | Всего | Занято | Свободно | % |
|------------|-------|--------|----------|---|
| /dev/nvme1n1p4 | 913G | 248G | 619G | 29% |
| /dev/nvme0n1p1 | 1.9T | 58G | 1.7T | 4% |

---

## Активные сервисы
```
accounts-daemon.service running
alsa-restore.service exited
apparmor.service exited
avahi-daemon.service running
banxe-api.service running
banxe-screener.service running
banxe-verify-api.service running
banxe-watchman.service running
bluetooth.service running
bolt.service running
clickhouse-server.service running
colord.service running
console-setup.service exited
containerd.service running
cron.service running
cups-browsed.service running
cups.service running
dbus.service running
deep-search.service running
docker.service running
fail2ban.service running
fwupd.service running
getty@tty1.service running
gnome-remote-desktop.service running
guiyon-bridge.service running
guiyon-dispatcher.service running
guiyon-project-api.service running
guiyon-tunnel.service running
guiyon-tunnel-url.service exited
hitl-dashboard.service running
kerneloops.service running
keyboard-setup.service exited
kmod-static-nodes.service exited
lightdm.service running
lm-sensors.service exited
ModemManager.service running
n8n.service running
NetworkManager.service running
NetworkManager-wait-online.service exited
nginx.service running
ollama.service running
openclaw-gateway-ctio.service running
openclaw-gateway-guiyon.service running
openclaw-gateway-moa.service running
openvpn.service exited
pii-proxy.service running
plymouth-quit-wait.service exited
plymouth-read-write.service exited
plymouth-start.service exited
polkit.service running
postgresql@16-main.service running
postgresql.service exited
power-profiles-daemon.service running
rsyslog.service running
rtkit-daemon.service running
setvtrgb.service exited
snapd.apparmor.service exited
snapd.seeded.service exited
snapd.service running
ssh.service running
switcheroo-control.service running
sysstat.service exited
systemd-binfmt.service exited
systemd-fsck@dev-disk-by\x2duuid-c1eb8547\x2d24d0\x2d4279\x2da148\x2d29a046526a38.service exited
systemd-fsck@dev-disk-by\x2duuid-D8EB\x2dF106.service exited
systemd-journald.service running
systemd-journal-flush.service exited
systemd-logind.service running
systemd-modules-load.service exited
systemd-oomd.service running
systemd-random-seed.service exited
systemd-remount-fs.service exited
systemd-resolved.service running
systemd-sysctl.service exited
systemd-timesyncd.service running
systemd-tmpfiles-setup-dev-early.service exited
systemd-tmpfiles-setup-dev.service exited
systemd-tmpfiles-setup.service exited
systemd-udevd.service running
systemd-udev-trigger.service exited
systemd-update-utmp.service exited
systemd-user-sessions.service exited
ubuntu-fan.service exited
udisks2.service running
ufw.service exited
unattended-upgrades.service running
upower.service running
user@0.service running
user@1000.service running
user-runtime-dir@0.service exited
user-runtime-dir@1000.service exited
wpa_supplicant.service running
xrdp.service running
xrdp-sesman.service running
```

## Порты
| Порт | Процесс |
|------|---------|
| 2222 | sshd |
| 3000 | docker-proxy |
| 3001 | docker-proxy |
| 3003 | docker-proxy |
| 3004 | docker-proxy |
| 3350 | xrdp-sesman |
| 3389 | xrdp |
| 4000 | docker-proxy |
| 5001 | docker-proxy |
| 5002 | docker-proxy |
| 5003 | docker-proxy |
| 5004 | docker-proxy |
| 5137 | docker-proxy |
| 5200 | docker-proxy |
| 5201 | docker-proxy |
| 5432 | docker-proxy |
| 5433 | postgres |
| 5678 | node |
| 5679 | node |
| 5703 | docker-proxy |
| 6379 | docker-proxy |
| 8001 | docker-proxy |
| 8080 | nginx |
| 8084 | banxe-watchman |
| 8085 | python3 |
| 8088 | python3 |
| 8089 | python3 |
| 8090 | python3 |
| 8091 | python |
| 8092 | python3 |
| 8093 | uvicorn |
| 8094 | python3 |
| 8095 | docker-proxy |
| 8123 | clickhouse-serv |
| 8181 | docker-proxy |
| 8888 | docker-proxy |
| 9000 | clickhouse-serv |
| 9004 | clickhouse-serv |
| 9005 | clickhouse-serv |
| 9009 | clickhouse-serv |
| 9094 | banxe-watchman |
| 9099 | docker-proxy |
| 11434 | ollama |
| 15432 | docker-proxy |
| 15433 | docker-proxy |
| 16379 | docker-proxy |
| 18001 | docker-proxy |
| 18789 | openclaw-gatewa |
| 18791 | openclaw-gatewa |
| 18794 | openclaw-gatewa |
| 35237 | ollama |
| 35341 | containerd |
| 40641 | cloudflared |
| 44779 | ollama |

---

## Ollama модели
| Модель | Размер | Изменена |
|--------|--------|----------|
| qwen3-banxe-v2:latest | 17.3 GB | 2026-04-03 |
| qwen3-banxe:latest | 17.3 GB | 2026-04-02 |
| qwen3:30b-a3b | 17.3 GB | 2026-04-02 |
| gurubot/gpt-oss-derestricted:20b | 14.7 GB | 2026-03-26 |
| huihui_ai/glm-4.7-flash-abliterated:latest | 17.5 GB | 2026-03-26 |

## ClickHouse
### Базы данных
- banxe

### Таблицы
| БД | Таблица | Размер | Строк | Движок |
|----|---------|--------|-------|--------|
| banxe | .inner_id.4855fd54-2854-49bc-8674-441e4c4dc5ae | 0.00 B | 0 | SummingMergeTree |
| banxe | .inner_id.66ba6d73-7cd9-4d64-95fb-98eeaea5c3c3 | 2.57 KiB | 3 | ReplacingMergeTree |
| banxe | .inner_id.a011adf9-b47b-49d5-97db-8ae354e25db4 | 985.00 B | 3 | SummingMergeTree |
| banxe | accounts | 0.00 B | 0 | ReplacingMergeTree |
| banxe | agent_metrics | 2.32 KiB | 3 | MergeTree |
| banxe | aml_alerts | 1.65 KiB | 9 | MergeTree |
| banxe | audit_trail | 0.00 B | 0 | MergeTree |
| banxe | compliance_screenings | 5.53 KiB | 7 | MergeTree |
| banxe | ctio_actions | 2.97 KiB | 2 | MergeTree |
| banxe | hitl_decisions | 0.00 B | 0 | MergeTree |
| banxe | kyc_events | 1.76 KiB | 21 | MergeTree |
| banxe | mv_daily_stats | 985.00 B | 3 | MaterializedView |
| banxe | mv_payment_daily_volume | 0.00 B | 0 | MaterializedView |
| banxe | mv_sar_queue | 2.57 KiB | 3 | MaterializedView |
| banxe | payment_events | 0.00 B | 0 | MergeTree |
| banxe | safeguarding_breaches | 0.00 B | 0 | MergeTree |
| banxe | safeguarding_events | 0.00 B | 0 | MergeTree |
| banxe | transactions | 1.81 KiB | 13 | MergeTree |
| banxe | verification_corpus | 0.00 B | 0 | MergeTree |
| banxe | verification_log | 1.54 KiB | 23 | MergeTree |

---

## Docker
### Контейнеры
| Имя | Образ | Статус | Порты |
|-----|-------|--------|-------|
| banxe-mock-aspsp | banxe-mock-aspsp:latest | Up 14 hours (healthy) | 0.0.0.0:8888->8888/tcp, [::]:8888->8888/tcp |
| banxe-frankfurter | hakanensari/frankfurter:latest | Up 15 hours | 0.0.0.0:8181->8080/tcp, [::]:8181->8080/tcp |
| midaz-ledger | lerianstudio/midaz-ledger:latest | Up 21 hours | 127.0.0.1:8095->3002/tcp |
| midaz-rabbitmq | rabbitmq:4.1.3-management-alpine | Up 22 hours (healthy) | 4369/tcp, 5671/tcp, 15671/tcp, 15691-15692/tcp, 25672/tcp, 127.0.0.1:3004->5672/tcp, 127.0.0.1:3003->15672/tcp |
| midaz-mongodb | mongo:8 | Up 22 hours (healthy) | 127.0.0.1:5703->27017/tcp |
| mirofish | ghcr.io/666ghj/mirofish:latest | Up 33 hours | 0.0.0.0:3001->3000/tcp, [::]:3001->3000/tcp, 0.0.0.0:5004->5001/tcp, [::]:5004->5001/tcp |
| banxe-marble-frontend | marble-src-marble-frontend | Up 4 days | 0.0.0.0:5003->8080/tcp |
| banxe-marble-firebase | andreysenov/firebase-tools | Up 3 days | 5000-5001/tcp, 8080/tcp, 8085/tcp, 9000/tcp, 127.0.0.1:4000->4000/tcp, 9005/tcp, 127.0.0.1:9099->9099/tcp, 9199/tcp |
| banxe-marble-backend | marble-src-marble-backend | Up 4 days | 127.0.0.1:5002->8080/tcp |
| banxe-marble-postgres | postgis/postgis:17-3.5 | Up 4 days (healthy) | 127.0.0.1:15433->5432/tcp |
| ballerine-postgres | sibedge/postgres-plv8:15.3-3.1.7 | Up 4 days (healthy) | 5432/tcp |
| kyb-app | ghcr.io/ballerine-io/kyb-app:dev | Up 4 days | 0.0.0.0:5201->80/tcp, [::]:5201->80/tcp |
| workflows-dashboard | ghcr.io/ballerine-io/workflows-dashboard:dev | Up 4 days | 0.0.0.0:5200->80/tcp, [::]:5200->80/tcp |
| backoffice | ghcr.io/ballerine-io/backoffice:dev | Up 4 days | 0.0.0.0:5137->80/tcp, [::]:5137->80/tcp |
| workflow-service | ghcr.io/ballerine-io/workflows-service:dev | Up 2 seconds | 0.0.0.0:3000->3000/tcp, [::]:3000->3000/tcp |
| jube.webapi | jube.app | Up 5 days (healthy) | 127.0.0.1:5001->5001/tcp |
| jube.jobs | jube.app | Up 4 days (healthy) | 5001/tcp |
| postgres | postgres:17 | Up 15 hours | 0.0.0.0:5432->5432/tcp, [::]:5432->5432/tcp, 127.0.0.1:15432->5432/tcp |
| redis | redis/redis-stack:latest | Up 5 days | 0.0.0.0:6379->6379/tcp, [::]:6379->6379/tcp, 0.0.0.0:8001->8001/tcp, [::]:8001->8001/tcp, 127.0.0.1:16379->6379/tcp, 127.0.0.1:18001->8001/tcp |

### Образы
| Образ | Размер |
|-------|--------|
| banxe-mock-aspsp:latest | 142MB |
| midaz-ledger-banxe:latest | 54.3MB |
| alpine/curl:latest | 13.9MB |
| marble-src-marble-frontend:latest | 757MB |
| marble-src-marble-backend:latest | 255MB |
| andreysenov/firebase-tools:latest | 1.47GB |
| <none>:<none> | 646MB |
| jube.app:latest | 646MB |
| mongo:8 | 950MB |
| postgis/postgis:17-3.5 | 637MB |
| postgres:17 | 453MB |
| lerianstudio/midaz-ledger:latest | 54.1MB |
| ghcr.io/666ghj/mirofish:latest | 8.88GB |
| postgres:17-alpine | 279MB |
| alpine:latest | 8.44MB |
| curlimages/curl:latest | 24.2MB |
| redis/redis-stack:latest | 895MB |
| ghcr.io/ballerine-io/kyb-app:dev | 90.3MB |
| ghcr.io/ballerine-io/workflows-service:dev | 880MB |
| ghcr.io/ballerine-io/backoffice:dev | 112MB |

---

## OpenClaw конфиги
| Файл | Mode | Port | Model | Params |
|------|------|------|-------|--------|
| `/home/guiyon/.openclaw-guiyon/openclaw.json` | local | 18794 | ? | ctx=? |
| `/home/guiyon/.openclaw/openclaw.json` | local | 18794 | ? | ctx=? |
| `/home/ctio/.openclaw-ctio/.openclaw/openclaw.json` | local | 18791 | ? | ctx=? |
| `/home/ctio/.openclaw-ctio/openclaw.json` | local | 18791 | ? | ctx=? |
| `/opt/openclaw/.openclaw/openclaw.json` | local | 18789 | ? | ctx=? |
| `/root/.openclaw-moa.bak.1774699360/openclaw.json` | local | ? | ? | ctx=? |
| `/root/.openclaw-moa.bak.1774699360/.openclaw-moa/openclaw.json` | ? | ? | ? | ctx=? |
| `/root/.openclaw-default/.openclaw/openclaw.json` | local | 18793 | ? | ctx=? |
| `/root/.openclaw-default/openclaw.json` | local | 18793 | ? | ctx=? |
| `/root/.openclaw-moa/.openclaw/openclaw.json` | local | 18789 | ? | ctx=? |
| `/root/.openclaw-moa/openclaw.json` | local | ? | {} | ctx=? |
| `/data/guiyon-project/CONFIG/openclaw/openclaw.json` | local | 18794 | ? | ctx=? |

---

## Cron задачи (все пользователи)

### root
```
0 */6 * * * /usr/local/bin/backup-clickhouse.sh
0 3 * * * /usr/local/bin/backup-openclaw.sh
*/5 * * * * /bin/bash /data/vibe-coding/memory-autosync-watcher.sh
*/5 * * * * /bin/bash /data/vibe-coding/ctio-watcher.sh
*/15 * * * * /bin/bash /usr/local/bin/watchdog-watcher.sh
*/2 * * * * /usr/local/bin/ctio-action-analyzer.sh >> /data/logs/action-analyzer.log 2>&1
0 2 * * * /usr/local/bin/workspace-injection-scan.sh >> /data/logs/injection-scan.log 2>&1
@reboot sleep 15 && python3 /data/guiyon-project/SCRIPTS/update_tunnel_url.py
*/2 * * * * /usr/local/bin/midaz-healthcheck.sh
0 7 * * 1-5 cd /data/banxe/banxe-emi-stack && MIDAZ_BASE_URL=http://localhost:8095 MIDAZ_ORG_ID=019d6301-32d7-70a1-bc77-0a05379ee510 MIDAZ_LEDGER_ID=019d632f-519e-7865-8a30-3c33991bba9c CLICKHOUSE_HOST=localhost STATEMENT_DIR=/data/banxe/statements bash /data/banxe/banxe-emi-stack/scripts/daily-recon.sh >> /var/log/banxe/recon.log 2>&1
```

---

## Пользователи с shell доступом
| User | Home | Shell |
|------|------|-------|
| root | /root | /bin/bash |
| banxe | /home/banxe | /bin/bash |
| user | /home/user | /bin/bash |
| ctio | /home/ctio | /bin/bash |
| postgres | /var/lib/postgresql | /bin/bash |

---

## Git репозитории на сервере
| Путь | Branch | Remote | Последний коммит |
|------|--------|--------|-----------------|


---

## Установленные Python пакеты (pip3)
| Пакет | Версия |
|-------|--------|
| accelerate | 1.13.0 |
| agate | 1.9.1 |
| aiohappyeyeballs | 2.6.1 |
| aiohttp | 3.13.5 |
| aiosignal | 1.4.0 |
| amdsmi | 24.7.1+2858e51 |
| annotated-doc | 0.0.4 |
| annotated-types | 0.7.0 |
| anyio | 4.13.0 |
| appdirs | 1.4.4 |
| argcomplete | 3.1.4 |
| asyncpg | 0.31.0 |
| attrs | 26.1.0 |
| Babel | 2.10.3 |
| backoff | 2.2.1 |
| bcc | 0.29.1 |
| bcrypt | 3.2.2 |
| bitsandbytes | 0.49.2 |
| blinker | 1.7.0 |
| boltons | 21.0.0 |
| bracex | 2.6 |
| Brlapi | 0.8.5 |
| brotli | 1.2.0 |
| certifi | 2026.2.25 |
| cffi | 2.0.0 |
| chardet | 5.2.0 |
| charset-normalizer | 3.4.6 |
| click | 8.3.2 |
| click-option-group | 0.5.9 |
| clickhouse-connect | 0.15.1 |

## Недавние установки (apt)
| Дата | Пакет |
|------|-------|
| 2026-04-04 06:23:45 | linux-headers-6.17.0-20-generic:amd64 |
| 2026-04-04 06:23:47 | linux-hwe-6.17-tools-6.17.0-20:amd64 |
| 2026-04-04 06:23:47 | linux-tools-6.17.0-20-generic:amd64 |
| 2026-04-05 21:07:51 | libjson-perl:all |
| 2026-04-05 21:07:51 | postgresql-client-common:all |
| 2026-04-05 21:07:51 | postgresql-common:all |
| 2026-04-05 21:07:51 | libcommon-sense-perl:amd64 |
| 2026-04-05 21:07:51 | libtypes-serialiser-perl:all |
| 2026-04-05 21:07:51 | libjson-xs-perl:amd64 |
| 2026-04-05 21:07:51 | libllvm17t64:amd64 |
| 2026-04-05 21:07:52 | libpq5:amd64 |
| 2026-04-05 21:07:52 | postgresql-client-16:amd64 |
| 2026-04-05 21:07:52 | postgresql-16:amd64 |
| 2026-04-05 21:07:52 | postgresql:all |
| 2026-04-05 21:07:52 | postgresql-client:all |

---

## Последние изменения на сервере
> Файлы изменённые с последнего сканирования


#### /home/ctio
- `/home/ctio/.openclaw-ctio/workspace/SYSTEM-STATE.md` (17262 bytes, 2026-04-07 13:15:02)
- `/home/ctio/.openclaw-ctio/workspace/MEMORY.md` (33818 bytes, 2026-04-07 13:15:02)

#### /opt
- `/opt/openclaw/workspace-moa/SYSTEM-STATE.md` (17262 bytes, 2026-04-07 13:15:02)
- `/opt/openclaw/workspace-moa/MEMORY.md` (33818 bytes, 2026-04-07 13:15:02)

#### /data
- `/data/guiyon-project/.git/FETCH_HEAD` (0 bytes, 2026-04-07 13:15:07)
- `/data/guiyon-project/.git/COMMIT_EDITMSG` (34 bytes, 2026-04-07 13:15:00)
- `/data/guiyon-project/.git/index` (33603 bytes, 2026-04-07 13:15:00)

#### /root
- `/root/.semgrep/settings.yml` (94 bytes, 2026-04-07 13:10:13)
- `/root/.openclaw-default/.openclaw/workspace/SYSTEM-STATE.md` (17262 bytes, 2026-04-07 13:15:02)
- `/root/.openclaw-default/.openclaw/workspace/MEMORY.md` (33818 bytes, 2026-04-07 13:15:02)
- `/root/.openclaw-moa/.openclaw/workspace/SYSTEM-STATE.md` (17262 bytes, 2026-04-07 13:15:02)
- `/root/.openclaw-moa/.openclaw/workspace/MEMORY.md` (33818 bytes, 2026-04-07 13:15:02)
- `/root/.openclaw-moa/.openclaw/workspace-moa/SYSTEM-STATE.md` (17262 bytes, 2026-04-07 13:15:02)
- `/root/.openclaw-moa/.openclaw/workspace-moa/MEMORY.md` (33818 bytes, 2026-04-07 13:15:02)
- `/root/.openclaw-moa/workspace-moa/SYSTEM-STATE.md` (17262 bytes, 2026-04-07 13:15:02)
- `/root/.openclaw-moa/workspace-moa/MEMORY.md` (33818 bytes, 2026-04-07 13:15:02)

---

## Команды CTIO (Олег) — последние
### /home/ctio/.bash_history
```

```

### /root/.bash_history (последние)
```

```

---

## Пути к сервисам (для агентов, read-only)
| Сервис | Подключение |
|--------|-------------|
| ClickHouse | localhost:9000, БД: banxe |
| Ollama API | http://localhost:11434 |
| Deep Search | http://localhost:8088 |
| PII Proxy | http://localhost:8089 |
| n8n | http://localhost:5678 |
| MetaClaw skills | /data/metaclaw/skills/ |
| Backups | /data/backups/ |
| Logs | /data/logs/ |
| Bot workspace (MoA) | /root/.openclaw-moa/workspace-moa/ |
| Bot workspace (mycarmibot) | /root/.openclaw-default/.openclaw/workspace/ |
| CTIO home | /home/ctio/ |
| CTIO bot profile | /home/ctio/.openclaw-ctio/ |

---

---

## Верификационные инструменты (КАНОН)

| Инструмент | Статус | Версия |
|------------|--------|--------|
| semgrep | ✓ ACTIVE | 1.156.0 |
| snyk | ✓ ACTIVE | 1.1303.2 |
| pre-commit | ✓ ACTIVE | pre-commit 4.5.1 |
| coderabbit | ○ CLI не установлен (GitHub OK) | — |


### Semgrep правила
- Файл: `.semgrep/banxe-rules.yml`
- Правил: 8

### Pre-commit hooks
- Статус: ✓ Настроены

---
_Генерируется автоматически ctio-watcher.sh v2. Не редактировать вручную._
