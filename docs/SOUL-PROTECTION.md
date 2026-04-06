# SOUL.md Protection Architecture

> Статус: **IMPLEMENTED** (2026-04-04)
> Задокументировано как завершённый workstream.

---

## Проблема (root cause)

При рестарте процесса OpenClaw Gateway происходила реинициализация workspace. OpenClaw имеет встроенный шаблон `SOUL.md` по умолчанию, который перезаписывал кастомный файл в `/root/.openclaw-moa/workspace-moa/SOUL.md`.

Затронутые workspace:
- `/root/.openclaw-moa/workspace-moa/SOUL.md` — **не был защищён**, перезаписывался
- `/home/mmber/.openclaw/workspace-moa/SOUL.md` — уже был защищён (`chattr +i`) до этого workstream

---

## Архитектура защиты

### Уровень 1 — Filesystem Immutability (chattr +i)

```
/root/.openclaw-moa/workspace-moa/SOUL.md       ← chattr +i  ✅
/home/mmber/.openclaw/workspace-moa/SOUL.md     ← chattr +i  ✅
```

Флаг `i` делает файл нередактируемым даже для root. Любая попытка OpenClaw перезаписать файл завершается ошибкой `Operation not permitted`.

### Уровень 2 — Canonical Source of Truth

```
/home/mmber/.openclaw-moa/soul-protected/SOUL.md  ← единственный источник истины
```

Файл не immutable — он редактируемый, это сознательно. Именно с него делаются все обновления.
Путь user-owned (`mmber`) — доступен для записи без sudo. Cron (root) читает его без проблем.

### Уровень 3 — Runtime Self-Healing (SOUL GUARD)

В `memory-autosync-watcher.sh` (cron `*/5 * * * *`) добавлен блок **SOUL GUARD**:

```
каждые 5 минут:
  md5(soul-protected/SOUL.md) → сравнить с md5(workspace/SOUL.md)
  если расходятся:
    chattr -i  →  cp soul-protected  →  chattr +i
    запись в /data/logs/memory-sync.log
```

Это защищает от сценариев:
- принудительный `chattr -i` каким-либо процессом
- ручное редактирование workspace напрямую
- OpenClaw обновление с новой логикой инициализации workspace

---

## Текущее состояние (verified 2026-04-04)

| Файл | chattr +i | Размер | Источник |
|------|-----------|--------|----------|
| `/home/mmber/.openclaw-moa/soul-protected/SOUL.md` | нет (mutable, user-owned) | — bytes | canonical |
| `/root/.openclaw-moa/workspace-moa/SOUL.md` | **да** | — bytes | из soul-protected |
| `/home/mmber/.openclaw/workspace-moa/SOUL.md` | **да** | 3086 bytes | из soul-protected |

Содержимое SOUL.md: compliance version с `/no_think`, Quick ACK, Compliance API calls, Sanctions thresholds.

---

## Управление (Runbook)

### Проверить статус

```bash
cd ~/vibe-coding && git pull
ssh gmktec "bash /data/vibe-coding/scripts/protect-soul.sh status"
```

Ожидаемый вывод:
```
📂 soul-protected (источник истины):  size=3086 bytes
🤖 Workspace main agent (root):  ✅ ЗАЩИЩЁН (chattr +i)
🏠 Workspace defaults (mmber):   ✅ ЗАЩИЩЁН (chattr +i)
```

### Обновить SOUL.md

1. Отредактировать canonical файл на Legion:
   ```bash
   # Редактируй локальную копию:
   nano ~/vibe-coding/docs/SOUL.md
   ```

2. Задеплоить на GMKtec:
   ```bash
   cd ~/vibe-coding && git add docs/SOUL.md && git commit -m "update: SOUL.md ..." && git push
   ssh gmktec "bash /data/vibe-coding/scripts/protect-soul.sh update /data/vibe-coding/docs/SOUL.md"
   ```

   Скрипт автоматически: обновит `soul-protected/` → задеплоит в оба workspace → применит `chattr +i`.

### Временно разблокировать (аварийное редактирование)

```bash
ssh gmktec "bash /data/vibe-coding/scripts/protect-soul.sh unlock"
# ... вносишь изменения вручную ...
ssh gmktec "bash /data/vibe-coding/scripts/protect-soul.sh deploy"
```

> Не забудь обновить soul-protected/ вручную перед deploy, иначе deploy восстановит старую версию.

### Повторный деплой (восстановить из soul-protected)

```bash
ssh gmktec "bash /data/vibe-coding/scripts/protect-soul.sh deploy"
```

---

## Скрипт управления

`scripts/protect-soul.sh` — **уже существует** в репозитории.

| Команда | Действие |
|---------|----------|
| `deploy` | soul-protected → оба workspace + chattr +i |
| `update /path` | cp → soul-protected, затем deploy |
| `unlock` | chattr -i на оба workspace |
| `status` | показать флаги + размеры |
| `verify` | хэш-проверка + авторестор (вызывается watcher) |

---

## Cross-references

- `docs/SOUL.md` — canonical SOUL.md контент (версия на Legion, синхронизируется с soul-protected)
- `docs/OPENCLAW-REFERENCE.md` — архитектура workspace (раздел "workspace paths", строка 744)
- `scripts/memory-autosync-watcher.sh` — содержит блок SOUL GUARD в конце файла
- `docs/MEMORY.md` — раздел "Задачи": SOUL.md deployment помечен DONE (2026-04-04)

---

## Разделение статусов

| Элемент | Статус |
|---------|--------|
| `chattr +i` на обоих SOUL.md | **already implemented** |
| `soul-protected/` canonical source | **already implemented** |
| SOUL GUARD в memory-autosync-watcher.sh | **already implemented** |
| `scripts/protect-soul.sh` | **already implemented** |
| Этот docs-файл | **documented now** |
| Ссылки из CLAUDE.md | **documented now** |
