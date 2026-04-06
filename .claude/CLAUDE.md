## EXECUTION DISCIPLINE (I-28, KA-11) — ЧИТАЙ ПЕРВЫМ

ПЕРЕД любым действием — проверь:
1. CEO сказал СТОП → **остановись немедленно**, не создавай файлы, не делай «полезных» шагов
2. Есть незавершённые IL → завершить их ПЕРВЫМ: `bash ~/banxe-architecture/scripts/il-check.sh`
3. Новая инструкция CEO → СРАЗУ добавь IL-запись в `~/banxe-architecture/INSTRUCTION-LEDGER.md`
4. НЕ переходи к следующей задаче без Proof в IL
5. НЕ делай ничего что CEO не запросил явно

Нарушение = архитектурный дефект уровня P1 (INVARIANTS.md I-28, CANON KA-11).

---

## Незавершённые задачи при старте сессии

Запусти: `bash ~/banxe-architecture/scripts/il-check.sh`
Если есть PENDING/IN_PROGRESS → сначала закрой их, потом берись за новое.
