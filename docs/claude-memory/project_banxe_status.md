---
name: BANXE AI Project Status
description: Статус проекта BANXE AI — что сделано, что в процессе, главные блокеры (по состоянию на 01.04.2026)
type: project
---

Общий прогресс: ~58% (обновлено 02.04.2026)

## Сделано ✅
- ClickHouse — база banxe работает, принимает данные
- SSH GMKtec ↔ Legion — настроено (порт 2222, алиасы)
- Eval suite — автоматический трекинг в ClickHouse
- Karpathy Loop — демо работает, nightly runs настроены
- MetaClaw — POC готов, склонирован
- HITL-архитектура — 10 AI-агентов с человеческими «дублёрами», логирование в ClickHouse для FCA audit trails
- Action Analyzer — развёрнут, работает по cron каждые 2 минуты
- n8n workflows — AML Transaction Monitor и KYC Onboarding запущены
- CTIO Watcher — автопуш docs/MEMORY.md на GitHub каждые 5 минут (синхронизируется в workspace бота)
- Vendor email drafты — подготовлены (Dow Jones, LexisNexis, Sumsub)
- Sanctions list — реализован (project_sanctions_list_2026.md): Категория A (BLOCK) + Категория B (EDD/HOLD), шаблоны ответов бота, памятка ОАЭ (>£10k elevated KYC)
- Ollama модели обновлены — активна qwen3:30b-a3b, старые модели удалены

## В процессе / не завершено ⏳
- **Бот «Олег»** — финальная настройка через @BotFather
- **Vendor sandbox access** — ожидание ответов (5–14 дней); emails так и не были отправлены — **главный блокер** для Compliance бота
- **MetaClaw** — полная установка (запланирована на следующую сессию)
- **Alice £500 workflow** — реальный замер времени не проведён
- **Action Analyzer** — /home/ctio/.bash_history не существует (Олег не логинился); auditd неактивен

## Критический баг (02.04.2026)
**SOUL.md перезаписывается OpenClaw при рестарте** — бот теряет правила и идентичность.
Предложенное решение: `scripts/fix-soul-persistent.sh` — скрипт для сохранения SOUL.md персистентным.
Статус: **PENDING** — не реализован.

## Последний контекст сессии (02.04.2026)
Извлечено из диалога: sanctions list готов, модели обновлены, SOUL.md баг выявлен.
Текущий вопрос: создать `scripts/fix-soul-persistent.sh`?

**Why:** BANXE — AI-проект в сфере финтех/compliance (FCA audit trails, AML, KYC). Главный блокер — vendor emails не отправлены. Новый критический баг — SOUL.md.
**How to apply:** Приоритеты: 1) fix SOUL.md, 2) vendor emails, 3) MetaClaw.
