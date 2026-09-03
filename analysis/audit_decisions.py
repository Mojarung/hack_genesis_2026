"""Аудит выходного формата: data/sample_routing_decisions.json как образец
и scripts/validate_10.rb как фактическая спецификация приёмки.

    uv run python audit_decisions.py
"""

from __future__ import annotations

import re

import polars as pl

from paylens.loaders import (
    REPO_ROOT,
    decisions_frame,
    load_decisions,
    load_providers_raw,
    load_queue_raw,
    load_reference,
)
from paylens.rules import SELF_PROVIDER, skip_map

pl.Config.set_tbl_rows(60)
pl.Config.set_tbl_cols(25)
pl.Config.set_tbl_width_chars(220)

VALIDATOR = REPO_ROOT / "scripts" / "validate_10.rb"

# Поля, которые ТЗ называет обязательными для routing_decisions_test.json.
TZ_REQUIRED_DECISION_FIELDS = ["operation_id", "selected_provider", "attempts", "simulated_result", "latency_sec"]
TZ_REQUIRED_ATTEMPT_FIELDS = ["provider", "decision", "reason"]


def section(title: str) -> None:
    print(f"\n{'=' * 78}\n{title}\n{'=' * 78}")


def sample_structure() -> None:
    section("1. Формат sample_routing_decisions.json")
    decisions = load_decisions()
    attempts = decisions_frame(decisions)

    decision_fields = sorted({k for d in decisions for k in d})
    attempt_fields = sorted({k for d in decisions for a in d["attempts"] for k in a})
    print(f"решений: {len(decisions)}")
    print(f"поля решения: {decision_fields}")
    print(f"поля попытки:  {attempt_fields}")
    print(f"поле details из примера ТЗ в образце: "
          f"{'есть' if 'details' in attempt_fields else 'ОТСУТСТВУЕТ'}")

    print(f"\nsimulated_result: {sorted({d['simulated_result'] for d in decisions})}")
    print(f"latency_sec: {sorted({d['latency_sec'] for d in decisions})} "
          f"— в образце константа, конверсия не симулируется")

    print("\nсловарь reason:")
    print(attempts.group_by("decision", "reason").agg(n=pl.len()).sort("decision", "n", descending=[False, True]))

    print("\nчисло попыток на заявку:")
    print(
        attempts.group_by("operation_id")
        .agg(attempts=pl.len(), providers=pl.col("provider"))
        .sort("operation_id")
    )

    print("\nитоговое распределение образца:")
    picked = pl.DataFrame([{"provider": d["selected_provider"]} for d in decisions])
    targets = {p["payment_system"]: p["traffic_percentage"] for p in load_providers_raw()}
    print(
        picked.group_by("provider")
        .agg(count=pl.len())
        .with_columns(
            share_pct=(pl.col("count") / len(decisions) * 100).round(1),
            target_pct=pl.col("provider").replace_strict(targets, default=None),
        )
        .sort("count", descending=True)
    )
    print("для сравнения, distribution из примера отчёта в ТЗ: "
          "vipay 2 (20%), payflow 2 (20%), quickpay 6 (60%)")


def attempts_semantics() -> None:
    section("2. Семантика attempts: это не хронология каскада")
    decisions = load_decisions()

    print("заявки, где selected стоит НЕ последним:")
    for d in decisions:
        last = d["attempts"][-1]
        if last["provider"] != d["selected_provider"]:
            trail = " -> ".join(f"{a['provider']}:{a['decision']}" for a in d["attempts"])
            print(f"  {d['operation_id']}: {trail}")

    print("\nвывод: в образце attempts = полный разбор кандидатов в порядке priority,")
    print("а не последовательность реальных попыток. Провайдер, до которого каскад")
    print("физически не дошёл (после selected), всё равно присутствует со своим skip.")

    print("\nпопадают ли в attempts eligible-, но не выбранные провайдеры:")
    queue = {op["operation_id"]: op for op in load_queue_raw()}
    external = [p for p in load_providers_raw() if p["payment_system"] != SELF_PROVIDER]
    for d in decisions:
        op = queue[d["operation_id"]]
        skips = skip_map(op, external)
        listed = {a["provider"] for a in d["attempts"]}
        eligible_not_listed = [
            p["payment_system"]
            for p in external
            if p["payment_system"] not in skips
            and p["payment_system"] not in listed
        ]
        if eligible_not_listed:
            print(f"  {d['operation_id']}: допустимы, но в attempts не попали — {eligible_not_listed}")
    print("вывод: образец перечисляет только выбранного и отсеянных по hard-фильтру.")
    print("Почему проиграл допустимый конкурент — из образца не видно, а баллы за это есть.")

    print(f"\nspacepayments встречается в attempts образца: "
          f"{any(a['provider'] == SELF_PROVIDER for d in decisions for a in d['attempts'])}")


def validator_contract() -> None:
    section("3. Что валидатор проверяет, а что нет")
    source = VALIDATOR.read_text(encoding="utf-8")

    structure_fields = re.search(r"%w\[(.*?)\]\.each do \|field\|", source)
    attempt_fields = re.findall(r"%w\[(.*?)\]\.each do \|field\|", source)
    print(f"обязательные поля решения по валидатору: {structure_fields.group(1).split()}")
    print(f"обязательные поля попытки по валидатору:  {attempt_fields[1].split()}")
    print(f"поля из ТЗ, которые валидатор НЕ требует: "
          f"{[f for f in TZ_REQUIRED_DECISION_FIELDS if f not in structure_fields.group(1).split()]}")

    allowed_decisions = re.search(r"%w\[(.*?)\]\.include\?\(attempt\['decision'\]\)", source)
    print(f"допустимые значения decision: {allowed_decisions.group(1).split()} — "
          f"третьего состояния завести нельзя, это ошибка структуры")

    checks = {
        "покрытие всех operation_id из очереди": "жёстко, ошибка",
        "структура полей": "жёстко, ошибка",
        "deterministic_cases: selected_provider == эталон": "жёстко, ошибка",
        "selected_provider входит в eligible по снапшоту": "жёстко, ошибка",
        "для провайдеров из skip_reasons_expected есть attempt с decision=skipped": "мягко, предупреждение",
    }
    print("\nчто проверяется:")
    for check, severity in checks.items():
        print(f"  [{severity}] {check}")

    print("\nчто НЕ проверяется:")
    for item in (
        "текст reason (сравнивается только сам факт skipped)",
        "simulated_result и latency_sec — вообще не читаются",
        "порядок attempts и то, что selected стоит последним",
        "что skipped-провайдер действительно недопустим (можно отсеять и по soft-причине)",
        "обновление состояния провайдеров между заявками (eligible считается по статике)",
        "лишние поля в решении и в attempt — игнорируются",
        "requests_per_minute_limit — поля нет в данных, проверки нет",
    ):
        print(f"  - {item}")

    print("\nследствие для стратегии: цепочку из нескольких попыток можно показывать")
    print("честно, а eligible-но-проигравших помечать decision=skipped с своей причиной —")
    print("валидатор это принимает, а объяснимость выигрывает.")


def fallback_risk() -> None:
    section("4. Риск fallback против deterministic_cases")
    reference = load_reference()
    queue = {op["operation_id"]: op for op in load_queue_raw()}
    providers = load_providers_raw()
    required = {c["operation_id"]: c["required_provider"] for c in reference["deterministic_cases"]}

    print("spacepayments проходит eligible-проверку валидатора всегда (исключение по имени),")
    print("поэтому формально им можно закрыть любую заявку. Но на этих кейсах это ошибка:")
    for op_id, provider in required.items():
        op = queue[op_id]
        print(f"  {op_id}: обязателен {provider}; выбор {SELF_PROVIDER} -> ❌ deterministic_case")

    print("\nусловие корректного fallback: внешних кандидатов не осталось.")
    external = [p for p in providers if p["payment_system"] != SELF_PROVIDER]
    empty = [op_id for op_id, op in queue.items() if len(skip_map(op, external)) == len(external)]
    print(f"заявок публичной очереди, где это выполняется: {len(empty)} {empty}")
    print("на боевой очереди так может не быть — fallback обязан быть реализован, "
          "но включаться только по факту пустого пула.")


def main() -> None:
    sample_structure()
    attempts_semantics()
    validator_contract()
    fallback_risk()


if __name__ == "__main__":
    main()
