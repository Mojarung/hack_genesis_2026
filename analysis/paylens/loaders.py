"""Загрузка файлов кейса в polars. Единственное место, где зашиты пути."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import polars as pl

REPO_ROOT = Path(__file__).resolve().parents[2]
DATA_DIR = REPO_ROOT / "data"
DERIVED_DIR = DATA_DIR / "derived"

HISTORY_CSV = DATA_DIR / "operations_history.csv"
PROVIDERS_JSON = DATA_DIR / "providers.json"
QUEUE_JSON = DATA_DIR / "operations_queue_10.json"
REFERENCE_JSON = DATA_DIR / "reference_decisions.json"
SAMPLE_DECISIONS_JSON = DATA_DIR / "sample_routing_decisions.json"

# Во всех файлах кейса время в ISO-8601 со смещением +03:00.
TIMESTAMP_FORMAT = "%Y-%m-%dT%H:%M:%S%:z"


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def load_history(path: Path = HISTORY_CSV) -> pl.DataFrame:
    """История роутинга. created_at приводим к datetime, сохраняя исходную строку."""
    return (
        pl.read_csv(path, infer_schema_length=None)
        .with_columns(
            created_at_raw=pl.col("created_at"),
            created_at=pl.col("created_at").str.to_datetime(TIMESTAMP_FORMAT),
            amount=pl.col("amount").cast(pl.Int64),
            latency_sec=pl.col("latency_sec").cast(pl.Int64),
        )
        .rename({"payment_system": "provider"})
    )


def load_providers(path: Path = PROVIDERS_JSON) -> tuple[dict[str, Any], pl.DataFrame]:
    """Возвращает (метаданные снапшота, таблицу провайдеров)."""
    raw = load_json(path)
    meta = {k: v for k, v in raw.items() if k != "providers"}
    frame = pl.DataFrame(raw["providers"], infer_schema_length=None, strict=False)
    return meta, frame


def load_providers_raw(path: Path = PROVIDERS_JSON) -> list[dict[str, Any]]:
    """Провайдеры как есть: списки банков и None-ы не переживают табличное представление."""
    return load_json(path)["providers"]


def load_queue(path: Path = QUEUE_JSON) -> pl.DataFrame:
    """Очередь заявок. payout_requisite разворачиваем в плоские колонки."""
    rows = load_json(path)
    flat = [
        {
            "operation_id": op["operation_id"],
            "created_at": op["created_at"],
            "amount": op["amount"],
            "bank": op["bank"],
            "card_brand": op.get("card_brand"),
            "requisite_kind": next(iter(op.get("payout_requisite") or {}), None),
            "sbp_phone": (op.get("payout_requisite") or {}).get("sbp", {}).get("phone"),
            "sbp_bank_name": (op.get("payout_requisite") or {}).get("sbp", {}).get("bank_name"),
        }
        for op in rows
    ]
    return pl.DataFrame(flat, infer_schema_length=None, strict=False).with_columns(
        created_at_raw=pl.col("created_at"),
        created_at=pl.col("created_at").str.to_datetime(TIMESTAMP_FORMAT),
    )


def load_queue_raw(path: Path = QUEUE_JSON) -> list[dict[str, Any]]:
    return load_json(path)


def load_reference(path: Path = REFERENCE_JSON) -> dict[str, Any]:
    return load_json(path)


def load_decisions(path: Path = SAMPLE_DECISIONS_JSON) -> list[dict[str, Any]]:
    return load_json(path)


def decisions_frame(decisions: list[dict[str, Any]]) -> pl.DataFrame:
    """Плоская таблица попыток: одна строка = одна запись attempts."""
    rows = [
        {
            "operation_id": d["operation_id"],
            "selected_provider": d.get("selected_provider"),
            "simulated_result": d.get("simulated_result"),
            "latency_sec": d.get("latency_sec"),
            "attempt_index": i,
            "provider": a.get("provider"),
            "decision": a.get("decision"),
            "reason": a.get("reason"),
            "details": a.get("details"),
        }
        for d in decisions
        for i, a in enumerate(d.get("attempts") or [])
    ]
    return pl.DataFrame(rows, infer_schema_length=None, strict=False)
