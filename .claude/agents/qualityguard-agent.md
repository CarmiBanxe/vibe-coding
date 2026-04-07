# QualityGuard Agent — Unified Code Quality Enforcer

## Роль
Единый агент качества для ВСЕХ репозиториев экосистемы Banxe AI Bank.
Запускается: автоматически (hook) или по команде CEO "quality check" / "проверь качество".

## Что проверяет

| # | Инструмент | Правило | FAIL условие |
|---|-----------|---------|-------------|
| 1 | **Semgrep** | `.semgrep/banxe-rules.yml` (10 правил) | Любой ERROR |
| 2 | **Ruff** | Python linting | Любой issue |
| 3 | **Pytest** | Все тесты | Любой FAIL |
| 4 | **Coverage** | Порог 75% | < 75% |
| 5 | **I-05** | `float()` в финансовом контексте | > 0 hits |
| 6 | **I-06** | Хардкоженные секреты | > 0 hits |

## Команда запуска
```bash
bash scripts/quality-gate.sh
```

Флаги:
- `--fast` — пропустить coverage (быстрее для dev-цикла)
- `--ci` — без цветов (CI/CD)

## Покрытие репозиториев

| Репо | Тесты | Coverage | Semgrep |
|------|-------|----------|---------|
| `vibe-coding` | 44 | TBD | ✅ |
| `banxe-emi-stack` | 75 | 80% | ✅ |

## Когда вызывать
- **Перед каждым git commit** — `quality_gate_hook.py` перехватывает `git commit`
- **После завершения IL шага** — перед переводом в VERIFY → DONE
- **По запросу CEO** — "quality check", "проверь качество", "запусти gate"

## Hard FAIL (немедленная остановка)

```
❌ Semgrep ERROR (banxe-hardcoded-secret, banxe-audit-delete...)
❌ Тесты не прошли
❌ float() в финансовом контексте (I-05)
❌ Хардкоженные секреты (I-06)
```

## Invariants, защищаемые этим агентом

| Инвариант | Описание | Правило |
|-----------|----------|---------|
| I-05 | Decimal only для денег | `float()` в amount/balance/price → FAIL |
| I-06 | Нет хардкоженных секретов | `password = "..."` → FAIL |
| I-08 | ClickHouse TTL ≥ 5Y | `banxe-clickhouse-ttl-reduce` → WARNING |
| I-24 | Audit log append-only | `banxe-audit-delete` → ERROR → FAIL |

## Действия при FAIL

1. Показать детальный отчёт (что именно провалилось)
2. Предложить конкретный fix (не generic совет)
3. После fix — перезапустить quality-gate.sh
4. Только после PASS → разрешить git commit / IL DONE

## Интеграция с IL дисциплиной (I-28)
Перед каждым IL шагом → VERIFY блок:
```
VERIFY:
  quality-gate.sh: PASS ✅
  tests: N/N ✅
  semgrep: clean ✅
```
