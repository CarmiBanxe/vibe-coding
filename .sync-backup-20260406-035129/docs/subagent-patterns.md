# Subagent Patterns v2.0 — Claude Code + 4 Partners

**Версия:** 2.0 (2026-04-06)  
**Применимость:** все проекты CarmiBanxe  
**Партнёры:** Claude Code · Aider CLI · MiroFish · Ruflo

---

## Когда использовать subagents

- Задача > 30 мин estimated
- Задача декомпозируется на 2+ независимых subtask
- Нужна параллельная верификация
- Нужна независимая перспектива (adversarial, simulation)

**Активация:** «используй паттерн RIV» / «parallel verify этот файл» / «запусти CA audit»

---

## Паттерн RIV: Research + Implement + Verify

**Когда:** новая функциональность с неизвестными зависимостями.

```
SA-1 (Research)     → изучить документацию, найти зависимости, вернуть spec
SA-2 (Implement)    → Aider CLI реализует по spec (aider-banxe.sh --full)
SA-3 (Verify)       → parallel-verify.sh --file <результат SA-2>
Main: синтез → commit
```

**Пример:** «Реализуй новый adapter для Chainalysis — паттерн RIV»

---

## Паттерн MFR: Multi-File Refactor

**Когда:** рефакторинг затрагивает N≥3 файлов независимо.

```
SA-1..SA-N (параллельно) → каждый SA — один файл через Aider
Main: объединить результаты → проверить импорты → pytest → commit
```

**Пример:** «Переименовать RiskLevel → RiskCategory во всех файлах — паттерн MFR»

---

## Паттерн CA: Compliance Audit

**Когда:** перед PR в compliance-критичный код.

```
SA-1 → Static analysis (semgrep --config .semgrep/)
SA-2 → OPA/Rego (opa test policies/)
SA-3 → pytest --no-cov -q
SA-4 → parallel-verify.sh --file <changed files>
Main: если SA-1..SA-4 все PASS → approve, иначе → список issues
```

**Пример:** «Audit PR перед мержем в main — паттерн CA»

---

## Паттерн PDG: Pre-Deploy Gate

**Когда:** перед деплоем на GMKtec production.

```
Phase A (параллельно — все 4 обязательны):
  SA-1 → pytest 747 tests
  SA-2 → semgrep + snyk
  SA-3 → policy drift check
  SA-4 → agent passport validation

Phase B (только если Phase A = 4/4 PASS):
  Main → bash scripts/deploy-sprint6.sh
         bash scripts/verify-production.sh
```

**Пример:** «Задеплой Sprint 10 — паттерн PDG»

---

## Паттерн MED: MiroFish-Enhanced Design

**Когда:** решение затрагивает human behaviour, fraud, regulatory, market reaction.

```
SA-1 (Aider)    → техническая реализация (aider-banxe.sh --banxe)
SA-2 (MiroFish) → симуляция поведения (run-simulation.sh <scenario>)
Main: синтез tech + simulation → если конфликт → эскалировать пользователю
```

**Триггеры для MiroFish:** «human approval», «FCA», «fraud pattern», «market reaction», «sanctions edge case»

**Пример:** «Добавь velocity check для crypto — паттерн MED»

---

## Быстрые команды

| Команда пользователя | Что делает Claude Code |
|---|---|
| `parallel verify <файл>` | запускает SA → parallel-verify.sh --file |
| `паттерн RIV` | 3 SA параллельно: research + implement + verify |
| `паттерн CA` | 4 SA compliance audit |
| `паттерн PDG` | pre-deploy gate перед SSH на GMKtec |
| `симуляция MiroFish <сценарий>` | SA → MED pattern |
| `рефакторинг MFR <файлы>` | N SA параллельно |

---

## Ограничения

- Subagents не имеют доступа к production data без явного разрешения
- MED/MiroFish — только если MiroFish deployed (:3000 responding)
- PDG Phase B (deploy) — требует явного подтверждения пользователя
- Максимум subagents одновременно: 4 (ограничение контекста)
