# GAP-6: Autoresearch Program (karpathy-style R&D Loop)

**Status:** DOCUMENTED — non-blocking backlog  
**Type:** Auxiliary R&D контур, НЕ production  
**Engine:** AutoResearchClaw (installed at `/opt/AutoResearchClaw/` on GMKtec)  
**Version:** 2026-04-06

---

## Роль в архитектуре

AutoResearchClaw — автономный R&D контур, работающий параллельно с production стеком.

```
Production stack (vibe-coding)
    ↑ lessons learned
AutoResearchClaw (GMKtec /opt/AutoResearchClaw/)
    ↓ optimized instructions / thresholds / scoring
MetaClaw skills bridge (/data/metaclaw/skills/)
```

**Не является:** продовым компонентом, не влияет на compliance решения напрямую.  
**Является:** источником улучшений для системных инструкций агентов, scoring весов, thresholds.

---

## Конфигурация (актуальная)

Файл: `/opt/AutoResearchClaw/config-ollama.yaml`

```yaml
llm:
  provider: "openai-compatible"
  base_url: "http://localhost:4000/v1"   # LiteLLM proxy
  api_key: "anything"
  primary_model: "qwen3-30b"             # через LiteLLM
  fallback_models: ["glm-4-flash"]

experiment:
  mode: "sandbox"
  time_budget_sec: 600
  max_iterations: 5

metaclaw_bridge:
  enabled: true
  lesson_to_skill:
    enabled: true
    min_severity: "warning"
    max_skills_per_run: 3
```

> ⚠️ Обновить base_url и модели в config-ollama.yaml (старый конфиг ссылается на `qwen3.5-abliterated:35b` — удалена).  
> Скрипт обновления: `bash scripts/setup-autoresearchclaw.sh`

---

## Pipeline (23 стадии, 8 фаз)

| Фаза | Стадии | Описание |
|------|--------|----------|
| A: Research Scoping | 1–2 | Формулировка темы, декомпозиция |
| B: Literature Discovery | 3–6 | Поиск, сбор, скрининг [GATE@5] |
| C: Knowledge Synthesis | 7–8 | Кластеризация, гипотезы |
| D: Experiment Design | 9–11 | Дизайн экспериментов [GATE@9] |
| E: Experiment Execution | 12–13 | Запуск, итерации |
| F: Analysis & Decision | 14–15 | Анализ, решение pivot/proceed |
| G: Paper Writing | 16–19 | Draft, peer review, revision |
| H: Finalization | 20–23 | Quality gate [GATE@20], экспорт |

---

## Приоритетные исследовательские темы (Banxe)

### AML/Compliance
- Оптимальные thresholds для velocity checks (текущий: 3 tx/час) на основе реальных FCA case studies
- False positive rate оптимизация в Watchman minMatch (текущий: 0.80)
- SAR auto-threshold tuning (текущий: ≥85 composite)

### Multi-agent
- Оптимальные промпты для HITL handoff (когда агент должен эскалировать vs решать сам)
- Calibration scoring агентов через promptfoo vs ClickHouse audit trail

### Regulatory
- EU AI Act Art.14 (human oversight) — best practices для EMI
- FCA PS7/24 compliance patterns для AI-based onboarding

---

## Запуск

```bash
# На GMKtec
ssh gmktec

cd /opt/AutoResearchClaw

# Активировать venv
source .venv/bin/activate

# Запуск с темой (simulated mode — без code execution)
researchclaw run \
  --topic "AML velocity threshold optimization for UK EMI" \
  --config config-ollama.yaml \
  --mode simulated \
  --auto-approve

# Запуск с code execution (sandbox mode)
researchclaw run \
  --topic "False positive optimization in sanctions screening" \
  --config config-ollama.yaml \
  --mode sandbox
```

---

## Интеграция с production стеком

Результаты autoresearch попадают в production через:

1. **MetaClaw skills bridge** — `lesson_to_skill: enabled: true` → новые skills в `/data/metaclaw/skills/`
2. **Ручной review** CEO/CTIO → одобрение → коммит в vibe-coding
3. **Compliance gate** — любые изменения thresholds через QRAA протокол

**ЗАПРЕЩЕНО:** автоматическое применение результатов autoresearch к production compliance коду без явного одобрения CEO.

---

## Config fix (требуется перед первым запуском)

```bash
ssh gmktec 'sed -i \
  -e "s|base_url:.*11434.*|base_url: \"http://localhost:4000/v1\"|" \
  -e "s|api_key: \"ollama\"|api_key: \"anything\"|" \
  -e "s|primary_model:.*qwen3.5.*|primary_model: \"qwen3-30b\"|" \
  /opt/AutoResearchClaw/config-ollama.yaml'
```

---

## Связанные файлы

- `/opt/AutoResearchClaw/RESEARCHCLAW_AGENTS.md` — полная документация pipeline
- `scripts/setup-autoresearchclaw.sh` — скрипт установки/обновления
- `docs/MEMORY.md` — статус GAP-6
