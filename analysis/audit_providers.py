"""Аудит data/providers.json: инвентарь полей, внутренняя непротиворечивость,
запасы по лимитам, покрытие банков, ёмкость снапшота.

    uv run python audit_providers.py
"""

from __future__ import annotations

import polars as pl

from paylens.loaders import load_history, load_providers, load_providers_raw, load_queue

pl.Config.set_tbl_rows(60)
pl.Config.set_tbl_cols(25)
pl.Config.set_tbl_width_chars(220)

# Поля, которые ТЗ предлагает довнести самим.
EXPECTED_EXTRA_FIELDS = [
    "volume_share_pct",
    "requests_per_minute_limit",
    "daily_turnover_min",
    "daily_turnover_max",
]


def section(title: str) -> None:
    print(f"\n{'=' * 78}\n{title}\n{'=' * 78}")


def inventory() -> None:
    section("1. Инвентарь полей")
    meta, frame = load_providers()
    print(f"метаданные снапшота: {meta}")
    print(f"провайдеров: {frame.height}")

    raw = load_providers_raw()
    all_fields = {key for provider in raw for key in provider}
    common = set(raw[0]).intersection(*[set(p) for p in raw[1:]])
    print(f"\nполя не у всех провайдеров: {sorted(all_fields - common)}")
    print(f"полей всего: {len(all_fields)}")

    print("\nnull-ы по полям (null = 'ограничения нет'):")
    nulls = frame.null_count().unpivot(variable_name="field", value_name="nulls").filter(pl.col("nulls") > 0)
    print(nulls)

    print(f"\nполя из ТЗ, которых в файле нет: "
          f"{[f for f in EXPECTED_EXTRA_FIELDS if f not in all_fields]}")


def consistency() -> None:
    section("2. Внутренняя непротиворечивость")
    raw = load_providers_raw()

    traffic_sum = sum(p["traffic_percentage"] for p in raw)
    print(f"сумма traffic_percentage: {traffic_sum} "
          f"({'ок, 100%' if traffic_sum == 100 else 'НЕ 100%'})")

    priorities = [p["priority"] for p in raw]
    print(f"priority: {priorities}, уникальны: {len(set(priorities)) == len(priorities)}")

    for p in raw:
        name = p["payment_system"]
        problems = []
        lo, hi = p["limit_amount_min"], p["limit_amount_max"]
        if lo is not None and hi is not None and lo > hi:
            problems.append("limit_amount_min > limit_amount_max")
        if p["daily_amount_limit"] is not None and p["daily_approved_amount"] > p["daily_amount_limit"]:
            problems.append("daily_approved_amount уже больше лимита")
        if p["in_progress_count_limit"] is not None and p["in_progress_count"] > p["in_progress_count_limit"]:
            problems.append("in_progress_count больше лимита")
        if p["in_progress_amount_limit"] is not None and p["in_progress_amount"] > p["in_progress_amount_limit"]:
            problems.append("in_progress_amount больше лимита")
        if p["provider_margin_pct"] > p["merchant_margin_pct"] and not p["allow_negative_agreement"]:
            problems.append("отрицательная маржа без allow_negative_agreement")
        if p["available_requisites"] == 0:
            problems.append("нет свободных реквизитов")
        if p["banks"] == [] and p["exclude_banks"]:
            problems.append("exclude_banks=true при пустом banks (ничего не исключает)")
        print(f"  {name:<14} {problems or 'проблем нет'}")

    print("\nмаржа (provider vs merchant):")
    print(
        pl.DataFrame(
            [
                {
                    "provider": p["payment_system"],
                    "provider_margin_pct": p["provider_margin_pct"],
                    "merchant_margin_pct": p["merchant_margin_pct"],
                    "spread_pct": round(p["merchant_margin_pct"] - p["provider_margin_pct"], 3),
                }
                for p in raw
            ]
        ).sort("spread_pct", descending=True)
    )


def headroom() -> None:
    section("3. Запасы по лимитам на момент снапшота")
    raw = load_providers_raw()
    rows = []
    for p in raw:
        daily_headroom = (
            None if p["daily_amount_limit"] is None else p["daily_amount_limit"] - p["daily_approved_amount"]
        )
        rows.append(
            {
                "provider": p["payment_system"],
                "traffic_pct": p["traffic_percentage"],
                "priority": p["priority"],
                "amount_min": p["limit_amount_min"],
                "amount_max": p["limit_amount_max"],
                "daily_used_pct": (
                    None
                    if p["daily_amount_limit"] is None
                    else round(p["daily_approved_amount"] / p["daily_amount_limit"] * 100, 1)
                ),
                "daily_headroom": daily_headroom,
                "inprog_amount_headroom": (
                    None
                    if p["in_progress_amount_limit"] is None
                    else p["in_progress_amount_limit"] - p["in_progress_amount"]
                ),
                "inprog_count_headroom": (
                    None
                    if p["in_progress_count_limit"] is None
                    else p["in_progress_count_limit"] - p["in_progress_count"]
                ),
                "requisites": p["available_requisites"],
                "conversion_24h": p["conversion_24h"],
                "latency_sec": p["avg_latency_sec"],
            }
        )
    print(pl.DataFrame(rows, infer_schema_length=None, strict=False).sort("priority"))

    print("\nсколько заявок влезет в запас дневного лимита при медианном чеке 25 000 ₽:")
    for row in rows:
        if row["daily_headroom"] is None:
            print(f"  {row['provider']:<14} без лимита")
        else:
            print(f"  {row['provider']:<14} {row['daily_headroom'] // 25_000:>4} шт "
                  f"(запас {row['daily_headroom']:,} ₽)")

    print("\nэффективный потолок по одной заявке (min от amount_max и всех запасов):")
    for p in raw:
        caps = [
            p["limit_amount_max"],
            None if p["daily_amount_limit"] is None else p["daily_amount_limit"] - p["daily_approved_amount"],
            None
            if p["in_progress_amount_limit"] is None
            else p["in_progress_amount_limit"] - p["in_progress_amount"],
        ]
        finite = [c for c in caps if c is not None]
        ceiling = min(finite) if finite else None
        print(f"  {p['payment_system']:<14} {ceiling if ceiling is not None else 'без потолка'}"
              f"   (amount_max={p['limit_amount_max']})")


def bank_coverage() -> None:
    section("4. Покрытие банков")
    raw = load_providers_raw()
    history_banks = set(load_history()["bank"].unique().to_list())
    queue_banks = set(load_queue()["bank"].unique().to_list())
    known_banks = sorted(history_banks | queue_banks)
    print(f"банки в истории: {sorted(history_banks)}")
    print(f"банки в очереди: {sorted(queue_banks)}")

    matrix = []
    for bank in known_banks:
        row: dict[str, object] = {"bank": bank}
        for p in raw:
            banks = p["banks"] or []
            if not banks:
                allowed = True
            elif p["exclude_banks"]:
                allowed = bank not in banks
            else:
                allowed = bank in banks
            row[p["payment_system"]] = "+" if allowed else "-"
        row["внешних вариантов"] = sum(
            1
            for p in raw
            if p["payment_system"] != "spacepayments" and row[p["payment_system"]] == "+"
        )
        matrix.append(row)
    print()
    print(pl.DataFrame(matrix))

    single = [r["bank"] for r in matrix if r["внешних вариантов"] == 1]
    print(f"\nбанки с единственным внешним провайдером: {single}")
    print("для них любая soft-цель бессильна: маршрут предопределён hard-фильтром")


def capacity() -> None:
    section("5. Ёмкость снапшота против очереди")
    queue = load_queue()
    raw = load_providers_raw()
    total = queue["amount"].sum()
    external_headroom = sum(
        p["daily_amount_limit"] - p["daily_approved_amount"]
        for p in raw
        if p["daily_amount_limit"] is not None
    )
    print(f"объём публичной очереди: {total:,} ₽ ({queue.height} заявок)")
    print(f"суммарный запас дневных лимитов внешних провайдеров: {external_headroom:,} ₽")
    print(f"очередь занимает {total / external_headroom:.1%} общего запаса — на 10 заявках "
          f"дневные лимиты не станут узким местом, кроме payflow")

    print("\nна сколько таких очередей хватит каждого провайдера в одиночку:")
    for p in raw:
        if p["daily_amount_limit"] is None:
            print(f"  {p['payment_system']:<14} без лимита")
            continue
        headroom_value = p["daily_amount_limit"] - p["daily_approved_amount"]
        print(f"  {p['payment_system']:<14} {headroom_value / total:>6.1f} очередей")


def main() -> None:
    inventory()
    consistency()
    headroom()
    bank_coverage()
    capacity()


if __name__ == "__main__":
    main()
