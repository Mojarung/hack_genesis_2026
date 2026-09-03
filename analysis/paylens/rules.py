"""Реплика hard-constraints из scripts/validate_10.rb.

Нужна только для аудита: сверять свои выводы с тем, как считает валидатор
организаторов. Боевая логика роутинга живёт в Ruby, здесь — зеркало для проверок.
Порядок проверок совпадает с валидатором, поэтому первая сработавшая причина —
та же, что назовёт он.
"""

from __future__ import annotations

from typing import Any

SELF_PROVIDER = "spacepayments"


def skip_reason(operation: dict[str, Any], provider: dict[str, Any]) -> str | None:
    """None — провайдер допущен; иначе код причины отсева."""
    amount = operation["amount"]
    bank = operation.get("bank")

    if provider.get("status") != "active":
        return "provider_inactive"
    if not provider.get("traffic_percentage") and provider["payment_system"] != SELF_PROVIDER:
        return "zero_traffic_share"
    if provider.get("limit_amount_min") is not None and amount < provider["limit_amount_min"]:
        return "amount_below_minimum"
    if provider.get("limit_amount_max") is not None and amount > provider["limit_amount_max"]:
        return "amount_exceeds_limit"
    if provider.get("daily_amount_limit") is not None and (
        (provider.get("daily_approved_amount") or 0) + amount > provider["daily_amount_limit"]
    ):
        return "daily_amount_limit_exceeded"
    if provider.get("in_progress_count_limit") is not None and (
        (provider.get("in_progress_count") or 0) + 1 > provider["in_progress_count_limit"]
    ):
        return "in_progress_count_limit_exceeded"
    if provider.get("in_progress_amount_limit") is not None and (
        (provider.get("in_progress_amount") or 0) + amount > provider["in_progress_amount_limit"]
    ):
        return "in_progress_amount_limit_exceeded"
    if not provider.get("available_requisites"):
        return "no_available_requisites"
    if (provider.get("provider_margin_pct") or 0) > (provider.get("merchant_margin_pct") or 0) and not provider.get(
        "allow_negative_agreement"
    ):
        return "negative_margin"

    banks = provider.get("banks") or []
    if banks:
        if provider.get("exclude_banks"):
            if bank in banks:
                return "bank_excluded"
        elif bank not in banks:
            return "bank_not_in_list"

    return None


def eligible(operation: dict[str, Any], providers: list[dict[str, Any]]) -> list[str]:
    return [p["payment_system"] for p in providers if skip_reason(operation, p) is None]


def skip_map(operation: dict[str, Any], providers: list[dict[str, Any]]) -> dict[str, str]:
    reasons = {p["payment_system"]: skip_reason(operation, p) for p in providers}
    return {name: reason for name, reason in reasons.items() if reason is not None}
