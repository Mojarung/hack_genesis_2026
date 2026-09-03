"""Аудит data/operations_history.csv: качество данных, конверсия, интенсивность,
согласованность истории с текущим снапшотом providers.json.

    uv run python audit_history.py
"""

from __future__ import annotations

import polars as pl

from paylens.loaders import load_history, load_providers_raw
from paylens.rules import skip_reason

pl.Config.set_tbl_rows(60)
pl.Config.set_tbl_cols(20)
pl.Config.set_tbl_width_chars(200)


def section(title: str) -> None:
    print(f"\n{'=' * 78}\n{title}\n{'=' * 78}")


def quality(history: pl.DataFrame) -> None:
    section("1. Качество данных")
    print(f"строк: {history.height}, колонок: {history.width}")
    print("\nсхема:")
    for name, dtype in history.drop("created_at_raw").schema.items():
        print(f"  {name:16} {dtype}")

    nulls = history.null_count().unpivot(variable_name="column", value_name="nulls").filter(pl.col("nulls") > 0)
    print(f"\nnull-ы: {nulls.to_dicts() if nulls.height else 'нет'}")

    empty_strings = {
        col: history.filter(pl.col(col).cast(pl.Utf8).str.strip_chars() == "").height
        for col in history.columns
        if history.schema[col] == pl.Utf8
    }
    print(f"пустые строки: { {k: v for k, v in empty_strings.items() if v} }")

    dup_ids = history.height - history["operation_id"].n_unique()
    dup_rows = history.height - history.drop("created_at_raw").unique().height
    print(f"дубли operation_id: {dup_ids}, полные дубли строк: {dup_rows}")

    ordered = history["created_at"].is_sorted()
    print(f"отсортировано по created_at: {ordered}")
    if not ordered:
        broken = (
            history.with_row_index("row")
            .with_columns(prev=pl.col("created_at").shift(1))
            .filter(pl.col("created_at") < pl.col("prev"))
        )
        print(f"  строк, нарушающих монотонность: {broken.height}, первые id: "
              f"{broken['operation_id'].head(5).to_list()}")

    print(f"\nсловари значений:")
    for col in ("bank", "provider", "status"):
        print(f"  {col:10} {sorted(history[col].unique().to_list())}")


def distribution(history: pl.DataFrame) -> None:
    section("2. Распределение сумм и латентности")
    print(history.select("amount", "latency_sec").describe())

    print("\nквантили amount:")
    for q in (0.1, 0.25, 0.5, 0.75, 0.9, 0.95):
        print(f"  p{int(q * 100):<3} {history['amount'].quantile(q):>10,.0f}")

    print("\nкратность сумм:")
    for step in (100, 500, 1000):
        share = history.filter(pl.col("amount") % step == 0).height / history.height
        print(f"  кратно {step:>5}: {share:.0%}")

    print("\nлатентность по статусу:")
    print(
        history.group_by("status")
        .agg(
            n=pl.len(),
            lat_min=pl.col("latency_sec").min(),
            lat_med=pl.col("latency_sec").median(),
            lat_max=pl.col("latency_sec").max(),
            amount_med=pl.col("amount").median(),
        )
        .sort("n", descending=True)
    )

    print("\nлатентность по провайдеру (факт) против avg_latency_sec из снапшота:")
    declared = {p["payment_system"]: p["avg_latency_sec"] for p in load_providers_raw()}
    stats = history.group_by("provider").agg(
        n=pl.len(),
        lat_mean=pl.col("latency_sec").mean().round(1),
        lat_med=pl.col("latency_sec").median(),
        lat_max=pl.col("latency_sec").max(),
        lat_mean_ok=pl.col("latency_sec").filter(pl.col("status") == "approved").mean().round(1),
        lat_med_ok=pl.col("latency_sec").filter(pl.col("status") == "approved").median(),
    )
    print(
        stats.with_columns(
            declared_avg=pl.col("provider").replace_strict(declared, default=None),
        ).sort("n", descending=True)
    )


def conversion(history: pl.DataFrame) -> None:
    section("3. Конверсия: провайдер × статус × банк × сумма")
    declared = {p["payment_system"]: p["conversion_24h"] for p in load_providers_raw()}

    by_provider = (
        history.group_by("provider")
        .agg(
            n=pl.len(),
            volume=pl.col("amount").sum(),
            approved=(pl.col("status") == "approved").sum(),
            rejected=(pl.col("status") == "rejected").sum(),
            expired=(pl.col("status") == "expired").sum(),
        )
        .with_columns(
            count_share=(pl.col("n") / history.height * 100).round(1),
            volume_share=(pl.col("volume") / history["amount"].sum() * 100).round(1),
            conv_fact=(pl.col("approved") / pl.col("n")).round(3),
            conv_declared=pl.col("provider").replace_strict(declared, default=None),
        )
    )
    print(
        by_provider.with_columns(delta=(pl.col("conv_fact") - pl.col("conv_declared")).round(3)).sort(
            "n", descending=True
        )
    )

    print("\nдоверительный интервал Уилсона 95% для конверсии (n мал, разброс велик):")
    for row in by_provider.sort("n", descending=True).iter_rows(named=True):
        low, high = wilson(row["approved"], row["n"])
        inside = low <= (row["conv_declared"] or 0) <= high
        print(
            f"  {row['provider']:<14} n={row['n']:<4} conv={row['conv_fact']:.3f} "
            f"CI=[{low:.3f}, {high:.3f}]  заявлено {row['conv_declared']}  "
            f"{'внутри CI' if inside else 'ВНЕ CI'}"
        )

    print("\nконверсия по банку:")
    print(
        history.group_by("bank")
        .agg(n=pl.len(), conv=(pl.col("status") == "approved").mean().round(3))
        .sort("n", descending=True)
    )

    print("\nпровайдер × банк (n / конверсия):")
    print(
        history.group_by("provider", "bank")
        .agg(n=pl.len(), conv=(pl.col("status") == "approved").mean().round(2))
        .pivot(on="bank", index="provider", values="n")
        .fill_null(0)
    )

    print("\nконверсия по бакету суммы:")
    buckets = history.with_columns(
        bucket=pl.when(pl.col("amount") <= 1000)
        .then(pl.lit("1. <=1k"))
        .when(pl.col("amount") <= 50_000)
        .then(pl.lit("2. 1k-50k"))
        .when(pl.col("amount") <= 100_000)
        .then(pl.lit("3. 50k-100k"))
        .otherwise(pl.lit("4. >100k"))
    )
    print(
        buckets.group_by("bucket")
        .agg(n=pl.len(), conv=(pl.col("status") == "approved").mean().round(3), volume=pl.col("amount").sum())
        .sort("bucket")
    )


def wilson(successes: int, total: int, z: float = 1.96) -> tuple[float, float]:
    if total == 0:
        return (0.0, 0.0)
    p = successes / total
    denom = 1 + z**2 / total
    centre = (p + z**2 / (2 * total)) / denom
    margin = z * ((p * (1 - p) / total + z**2 / (4 * total**2)) ** 0.5) / denom
    return (max(0.0, centre - margin), min(1.0, centre + margin))


def intensity(history: pl.DataFrame) -> None:
    section("4. Интенсивность потока (калибровка requests_per_minute_limit)")
    ordered = history.sort("created_at")
    gaps = ordered.select(gap=pl.col("created_at").diff().dt.total_seconds()).drop_nulls()
    print(f"окно: {ordered['created_at'].min()} .. {ordered['created_at'].max()}")
    print(f"межзаявочный интервал, сек: медиана {gaps['gap'].median():.0f}, "
          f"min {gaps['gap'].min():.0f}, max {gaps['gap'].max():.0f}")

    per_minute = (
        ordered.group_by_dynamic("created_at", every="1m").agg(n=pl.len()).select("n").to_series()
    )
    print(f"заявок в минуту: медиана {per_minute.median():.1f}, максимум {per_minute.max()}")

    print("\nпик по провайдеру за минуту:")
    print(
        ordered.sort("created_at")
        .group_by_dynamic("created_at", every="1m", group_by="provider")
        .agg(n=pl.len())
        .group_by("provider")
        .agg(peak_per_min=pl.col("n").max(), busy_minutes=pl.len())
        .sort("peak_per_min", descending=True)
    )


def snapshot_consistency(history: pl.DataFrame) -> None:
    section("5. История против снапшота providers.json")
    providers = {p["payment_system"]: p for p in load_providers_raw()}

    rows = history.select("operation_id", "amount", "bank", "provider", "status").to_dicts()
    violations = []
    for row in rows:
        provider = providers.get(row["provider"])
        if provider is None:
            violations.append({**row, "reason": "provider_not_in_snapshot"})
            continue
        reason = skip_reason({"amount": row["amount"], "bank": row["bank"]}, provider)
        if reason and reason not in {"daily_amount_limit_exceeded", "in_progress_amount_limit_exceeded"}:
            violations.append({**row, "reason": reason})

    frame = pl.DataFrame(violations) if violations else pl.DataFrame()
    print(
        f"строк истории, невозможных при текущем снапшоте: {len(violations)} из {history.height} "
        f"({len(violations) / history.height:.0%})"
    )
    if violations:
        print(frame.group_by("provider", "reason").agg(n=pl.len()).sort("n", descending=True))
        print("\nпримеры:")
        print(frame.head(8))

    print("\nодобренный объём по провайдерам за день истории против daily_approved_amount снапшота:")
    approved = (
        history.filter(pl.col("status") == "approved")
        .group_by("provider")
        .agg(approved_volume=pl.col("amount").sum(), n=pl.len())
    )
    print(
        approved.with_columns(
            snapshot_daily_approved=pl.col("provider").replace_strict(
                {name: p["daily_approved_amount"] for name, p in providers.items()}, default=None
            ),
            daily_limit=pl.col("provider").replace_strict(
                {name: p["daily_amount_limit"] for name, p in providers.items()}, default=None
            ),
        ).sort("approved_volume", descending=True)
    )


def main() -> None:
    history = load_history()
    quality(history)
    distribution(history)
    conversion(history)
    intensity(history)
    snapshot_consistency(history)


if __name__ == "__main__":
    main()
