"""Аудит data/operations_queue_10.json и data/reference_decisions.json:
структура заявки, матрица допустимости, сверка с эталоном организаторов,
во что упирается распределение на этой очереди.

    uv run python audit_queue.py
"""

from __future__ import annotations

import polars as pl

from paylens.loaders import load_providers_raw, load_queue, load_queue_raw, load_reference
from paylens.rules import SELF_PROVIDER, eligible, skip_map

pl.Config.set_tbl_rows(60)
pl.Config.set_tbl_cols(25)
pl.Config.set_tbl_width_chars(220)


def section(title: str) -> None:
    print(f"\n{'=' * 78}\n{title}\n{'=' * 78}")


def structure() -> None:
    section("1. Структура заявок")
    raw = load_queue_raw()
    queue = load_queue()
    print(f"заявок: {len(raw)}")

    all_fields = {k for op in raw for k in op}
    common = set(raw[0]).intersection(*[set(op) for op in raw[1:]])
    print(f"поля: {sorted(all_fields)}")
    print(f"необязательные (есть не у всех): {sorted(all_fields - common) or 'нет'}")

    print(f"\ncard_brand: {queue['card_brand'].to_list()}")
    print(f"виды реквизитов: {queue['requisite_kind'].unique().to_list()}")
    print(f"дубли operation_id: {queue.height - queue['operation_id'].n_unique()}")
    print(f"отсортировано по created_at: {queue['created_at'].is_sorted()}")

    gaps = queue.sort("created_at").select(gap=pl.col("created_at").diff().dt.total_seconds()).drop_nulls()
    print(f"интервал между заявками, сек: {sorted(set(gaps['gap'].to_list()))} "
          f"(окно {queue['created_at'].min()} .. {queue['created_at'].max()})")

    print("\nсоответствие bank (slug) и payout_requisite.sbp.bank_name:")
    print(
        queue.group_by("bank", "sbp_bank_name")
        .agg(n=pl.len())
        .sort("bank")
    )
    print("телефоны: 11 цифр, начинаются с 7 — "
          f"{queue['sbp_phone'].str.contains(r'^7\d{10}$').all()}")

    print("\nзаявки:")
    print(queue.select("operation_id", "created_at_raw", "amount", "bank", "sbp_bank_name"))


def eligibility() -> None:
    section("2. Матрица допустимости (по статическому снапшоту)")
    raw_queue = load_queue_raw()
    providers = load_providers_raw()
    names = [p["payment_system"] for p in providers]

    rows = []
    for op in raw_queue:
        skips = skip_map(op, providers)
        row: dict[str, object] = {"operation_id": op["operation_id"], "amount": op["amount"], "bank": op["bank"]}
        for name in names:
            row[name] = skips.get(name, "OK")
        row["внешних"] = sum(1 for n in names if n != SELF_PROVIDER and n not in skips)
        rows.append(row)
    frame = pl.DataFrame(rows)
    print(frame)

    print("\nсколько заявок допускает каждый провайдер:")
    for name in names:
        allowed = frame.filter(pl.col(name) == "OK").height
        print(f"  {name:<14} {allowed:>2} / {frame.height}")

    print("\nраспределение причин отсева:")
    reasons = (
        frame.unpivot(on=names, index="operation_id", variable_name="provider", value_name="verdict")
        .filter(pl.col("verdict") != "OK")
        .group_by("verdict")
        .agg(n=pl.len())
        .sort("n", descending=True)
    )
    print(reasons)

    forced = frame.filter(pl.col("внешних") == 1)
    print(f"\nзаявок с единственным внешним провайдером: {forced.height} "
          f"({forced['operation_id'].to_list()})")
    print(f"заявок без единого внешнего провайдера (нужен fallback): "
          f"{frame.filter(pl.col('внешних') == 0).height}")


def reference_crosscheck() -> None:
    section("3. Сверка с reference_decisions.json")
    reference = load_reference()
    raw_queue = load_queue_raw()
    providers = load_providers_raw()
    external = [p for p in providers if p["payment_system"] != SELF_PROVIDER]

    print("а) eligible_providers из эталона против нашего расчёта")
    mismatches = 0
    for op in raw_queue:
        op_id = op["operation_id"]
        expected = reference["eligible_providers"].get(op_id, [])
        ours_external = eligible(op, external)
        ours_all = eligible(op, providers)
        flag = "" if expected == ours_external else "  <-- РАСХОЖДЕНИЕ"
        mismatches += expected != ours_external
        print(f"  {op_id}: эталон={expected} наши(внешние)={ours_external} "
              f"наши(все)={ours_all}{flag}")
    print(f"  расхождений по внешним провайдерам: {mismatches}")
    print(f"  spacepayments в эталонных списках: "
          f"{any(SELF_PROVIDER in v for v in reference['eligible_providers'].values())}")

    print("\nб) deterministic_cases: действительно ли провайдер единственный")
    for case in reference["deterministic_cases"]:
        op = next(o for o in raw_queue if o["operation_id"] == case["operation_id"])
        ours = eligible(op, external)
        verdict = "ок" if ours == [case["required_provider"]] else f"ВНИМАНИЕ: наш расчёт {ours}"
        print(f"  {case['operation_id']}: требуется {case['required_provider']} -> {verdict}")

    print("\nв) skip_reasons_expected: полнота и совпадение кодов")
    for op in raw_queue:
        op_id = op["operation_id"]
        expected = reference["skip_reasons_expected"].get(op_id, {})
        ours = {k: v for k, v in skip_map(op, external).items()}
        missing = {k: v for k, v in ours.items() if k not in expected}
        extra = {k: v for k, v in expected.items() if k not in ours}
        differing = {k: (expected[k], ours[k]) for k in expected if k in ours and expected[k] != ours[k]}
        note = []
        if missing:
            note.append(f"нет в эталоне: {missing}")
        if extra:
            note.append(f"лишнее в эталоне: {extra}")
        if differing:
            note.append(f"разные коды: {differing}")
        print(f"  {op_id}: {'; '.join(note) if note else 'совпадает'}")


def distribution_pressure() -> None:
    section("4. Во что упирается распределение на этой очереди")
    raw_queue = load_queue_raw()
    providers = load_providers_raw()
    external = [p for p in providers if p["payment_system"] != SELF_PROVIDER]
    targets = {p["payment_system"]: p["traffic_percentage"] for p in external}

    allowed_counts = {p["payment_system"]: 0 for p in external}
    allowed_volume = {p["payment_system"]: 0 for p in external}
    for op in raw_queue:
        for name in eligible(op, external):
            allowed_counts[name] += 1
            allowed_volume[name] += op["amount"]

    total = len(raw_queue)
    total_volume = sum(op["amount"] for op in raw_queue)
    print("потолок доли: сколько заявок провайдер вообще может взять, даже забрав всё что можно")
    for name, count in allowed_counts.items():
        print(
            f"  {name:<10} допускает {count:>2}/{total} заявок = потолок доли {count / total:>5.0%} "
            f"при цели {targets[name]:>2}%  "
            f"{'ЦЕЛЬ НЕДОСТИЖИМА' if count / total * 100 < targets[name] else ''}"
        )

    print("\nто же по объёму:")
    for name, volume in allowed_volume.items():
        print(f"  {name:<10} допускает {volume:>9,} ₽ = потолок {volume / total_volume:>5.0%} объёма")

    print("\nминимальная доля провайдера (заявки, где он единственный внешний):")
    for name in targets:
        forced = [op for op in raw_queue if eligible(op, external) == [name]]
        forced_volume = sum(op["amount"] for op in forced)
        print(
            f"  {name:<10} пол по count {len(forced) / total:>4.0%}, по объёму "
            f"{forced_volume / total_volume:>4.0%} — {[op['operation_id'] for op in forced]}"
        )

    print("\nчистый каскад по priority (без soft-целей), стейт не обновляем:")
    cascade: dict[str, list[str]] = {p["payment_system"]: [] for p in external}
    for op in raw_queue:
        for provider in sorted(external, key=lambda p: p["priority"]):
            if provider["payment_system"] in eligible(op, external):
                cascade[provider["payment_system"]].append(op["operation_id"])
                break
    for name, ops in cascade.items():
        print(f"  {name:<10} {len(ops)}/{total} = {len(ops) / total:>4.0%} "
              f"(цель {targets[name]}%)  {ops}")

    print("\nдневной лимит payflow при каскаде:")
    payflow = next(p for p in external if p["payment_system"] == "payflow")
    used = payflow["daily_approved_amount"]
    limit = payflow["daily_amount_limit"]
    for op_id in cascade["payflow"]:
        amount = next(o["amount"] for o in raw_queue if o["operation_id"] == op_id)
        used += amount
        print(f"  после {op_id} (+{amount:,}): {used:,} / {limit:,} = {used / limit:.1%}")
    print(f"  остаток запаса: {limit - used:,} ₽")


def main() -> None:
    structure()
    eligibility()
    reference_crosscheck()
    distribution_pressure()


if __name__ == "__main__":
    main()
