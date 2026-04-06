#!/usr/bin/env python3
"""
Structured JSON logger для AML-движков. Factor XI compliance.

Формат: одна строка JSON на событие.
Destination: stdout (→ ClickHouse pipeline) + /data/banxe/data/logs/

Correlation ID: tx_id + case_id + scenario_id связывают все события
по одной транзакции в единую цепочку — это и replay capability (G-01),
и Factor XI compliance (G-20).

Usage:
    from compliance.utils.structured_logger import get_logger

    log = get_logger("sanctions_check")
    log.event("SANCTIONS_HIT", {
        "customer_id": "C12345",
        "rule": "SANCTIONS_CONFIRMED",
        "score": 100,
        "match_score": 0.97,
    }, tx_id=tx_id, case_id=case_id, scenario_id="SCN-002")

    log.decision("REJECT", composite_score=95, tx_id=tx_id)
    log.warning_event("YENTE_UNAVAILABLE", {"fallback": "watchman"}, tx_id=tx_id)
    log.error_event("REDIS_WRITE_FAIL", {"key": "banxe:emergency_stop"})

Closes: GAP-REGISTER G-20 (Factor XI compliance logging)
Supports: replay_decision.py (G-01 partial) via correlation IDs
"""
from __future__ import annotations

import json
import sys
from datetime import datetime, timezone
from typing import Any


_LOG_LEVELS = frozenset({"DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"})


class StructuredLogger:
    """
    Пишет одну строку JSON на событие в stdout.
    stdout в production → ClickHouse ingest pipeline.

    Correlation fields (tx_id, case_id, scenario_id) позволяют одним
    запросом в ClickHouse найти все события по транзакции:
        SELECT * FROM banxe.audit_trail WHERE tx_id = ?
    """

    def __init__(self, module: str) -> None:
        self.module = module

    def event(
        self,
        event_type: str,
        payload: dict[str, Any] | None = None,
        *,
        tx_id: str | None = None,
        case_id: str | None = None,
        scenario_id: str | None = None,
        customer_id: str | None = None,
        level: str = "INFO",
    ) -> None:
        """
        Основной метод логирования.

        Args:
            event_type:   Верхний регистр, underscore-разделённый (SANCTIONS_HIT, TX_HOLD, etc.)
            payload:      Дополнительные поля события (rule, score, match_score и т.д.)
            tx_id:        ID транзакции — primary correlation key
            case_id:      ID кейса в Marble
            scenario_id:  SCN-NNN из scenario_registry.yaml
            customer_id:  ID клиента
            level:        INFO | WARNING | ERROR | CRITICAL
        """
        if level not in _LOG_LEVELS:
            level = "INFO"

        record: dict[str, Any] = {
            "ts":          datetime.now(timezone.utc).isoformat(),
            "level":       level,
            "module":      self.module,
            "event":       event_type,
            "tx_id":       tx_id,
            "case_id":     case_id,
            "scenario_id": scenario_id,
            "customer_id": customer_id,
        }
        if payload:
            record.update(payload)

        # None-значения убираем — не засоряют ClickHouse
        record = {k: v for k, v in record.items() if v is not None}

        print(json.dumps(record, ensure_ascii=False, default=str), flush=True)

    # ── Convenience methods ────────────────────────────────────────────────────

    def decision(
        self,
        outcome: str,
        *,
        composite_score: int | float | None = None,
        tx_id: str | None = None,
        case_id: str | None = None,
        scenario_id: str | None = None,
        customer_id: str | None = None,
        requires_mlro: bool = False,
        **extra: Any,
    ) -> None:
        """Логирует финальное compliance-решение (APPROVE/HOLD/REJECT/SAR)."""
        payload: dict[str, Any] = {"outcome": outcome, "requires_mlro": requires_mlro}
        if composite_score is not None:
            payload["composite_score"] = composite_score
        payload.update(extra)
        self.event(
            "COMPLIANCE_DECISION",
            payload,
            tx_id=tx_id,
            case_id=case_id,
            scenario_id=scenario_id,
            customer_id=customer_id,
        )

    def warning_event(
        self,
        event_type: str,
        payload: dict[str, Any] | None = None,
        *,
        tx_id: str | None = None,
        **kwargs: Any,
    ) -> None:
        """WARNING-уровень — деградация сервиса, fallback активирован."""
        self.event(event_type, payload, tx_id=tx_id, level="WARNING", **kwargs)

    def error_event(
        self,
        event_type: str,
        payload: dict[str, Any] | None = None,
        *,
        tx_id: str | None = None,
        **kwargs: Any,
    ) -> None:
        """ERROR-уровень — сбой компонента, требует внимания."""
        self.event(event_type, payload, tx_id=tx_id, level="ERROR", **kwargs)

    def critical_event(
        self,
        event_type: str,
        payload: dict[str, Any] | None = None,
        *,
        tx_id: str | None = None,
        **kwargs: Any,
    ) -> None:
        """CRITICAL-уровень — security/compliance-событие (EMERGENCY_STOP, SAR_FILED)."""
        self.event(event_type, payload, tx_id=tx_id, level="CRITICAL", **kwargs)


def get_logger(module: str) -> StructuredLogger:
    """
    Фабричная функция. Создаёт StructuredLogger с именем модуля.

    Args:
        module: Имя AML-движка ("sanctions_check", "tx_monitor", "crypto_aml", etc.)

    Returns:
        StructuredLogger instance.

    Example:
        log = get_logger("sanctions_check")
        log.event("SANCTIONS_HIT", {"rule": "SANCTIONS_CONFIRMED", "score": 100},
                  tx_id=tx_id, scenario_id="SCN-002")
    """
    return StructuredLogger(module)
