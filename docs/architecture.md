# Архитектура PayoutRouter

## Принципы

1. **Hard отделён от soft.** Допуск (`Constraints`) и предпочтение (`Strategies` + `Scoring`) — разные
   слои с разными контрактами: правило допуска возвращает «можно/нельзя + причина», цель — оценку 0..1.
2. **Всё, что бизнес захочет крутить, лежит в политике.** Набор и порядок hard-правил, веса целей,
   диапазоны сумм, обязательства по обороту, интенсивность, fallback, режим симуляции — `config/policy.yml`.
   Код не меняется.
3. **Новая сущность = новый класс + строка в реестре.** Hard-правило, цель, правило рекомендаций —
   наследник `Base` с одним методом. Реестр (`Registry`) отдаёт класс по ключу из YAML и ловит опечатки.
4. **Конфигурация неизменяема, состояние явно.** `Domain::*` — `Data`, `State::*` — единственное место,
   где что-то меняется по ходу роутинга.
5. **Каждое решение объяснимо по построению.** Причина отсева, скор и его разложение по целям — не
   лог, а часть результата (`Attempt`).

## Поток данных

```
Inputs::ProvidersLoader ─► Domain::Snapshot ─┐
Inputs::PolicyLoader ───► Domain::Policy ───┼─► Policy#apply ─► Snapshot с overrides и fallback
Inputs::HistoryLoader ──► [HistoryRecord] ──► Analytics::HistoryStats
Inputs::QueueLoader ────► [Operation]
                                  │
Routing::BatchRouter (сортирует по created_at, отдаёт в порядке входа)
  └─ Routing::Router#route(operation)
       ├─ Ledger#settle_due(now)                    — ответы, чьё время пришло, освобождают in-progress
       ├─ Constraints::Pipeline#evaluate(candidate) — Evaluation(violations) для каждого внешнего
       ├─ Scoring::CompositeScorer#rank(eligible)   — [Score] по убыванию, tie-breakers
       ├─ dispatch → Simulation#call → Ledger#dispatch! (in-progress, реквизит, время отправки)
       │    approved → Decision; rejected/expired → следующий по рангу
       └─ fallback → self-provider (тоже через Pipeline) → иначе unrouted
                                  │
Analytics::RoutingStats + HistoryStats ─► ReportBuilder ─► Recommendations::Engine
Output::JSONWriter ─► routing_decisions.json, routing_report.json
```

## Модель времени

Заявки обрабатываются в хронологическом порядке. Отправка провайдеру занимает реквизит и место
в in-progress; ответ приходит через `latency_sec` и лежит в `State::SettlementQueue` (min-heap по
времени). Перед каждой заявкой леджер применяет все ответы, чьё время наступило: одобренные суммы
попадают в `daily_approved_amount`, in-progress и реквизиты освобождаются. Так лимиты одновременных
заявок и интенсивность (`requests_within(now)` — скользящая минута) считаются честно, а не «после каждой
заявки всё сразу обнулилось».

## Скоринг

`total = Σ weight_i × score_i / Σ weight_i` по включённым целям (вес > 0). Каждая цель возвращает
`Signal(score ∈ [0, 1], note)`; `note` попадает в `breakdown` попытки. Сортировка — по `total`, при
равенстве — `tie_breakers` из политики (`priority`, `conversion`, `latency`, `name`).

Формулы долей: `0.5 + (target − actual) / 100`. Провайдер на цели получает 0.5, каждые 10 п.п.
недобора добавляют 0.1. Первую заявку получает провайдер с наибольшей целью, затем недобирающие —
получается взвешенный round-robin без явного счётчика.

Конфликт целей решается весами: «vipay хочет 40%, но исчерпал дневной лимит» — `traffic_share` даёт
ему высокую оценку, `load` — низкую, итог зависит от весов, и это видно в `breakdown`. Недостижимая
цель (провайдер не проходит hard-правила) не участвует в скоринге вовсе; отчёт (`target_attainability`)
показывает, в какой доле заявок провайдер был допустим и что его блокировало, а правило
`share_shortfall` предлагает либо расширить фильтр, либо снизить цель.

## Семантика решений

- `decision: selected` — ровно одна попытка, её `provider` = `selected_provider`.
- `skipped` с причиной из `Reasons::HARD` — не прошёл hard-правило (`violations` перечисляет все).
- `skipped/lower_score` — допустим, но проиграл по скору (`score`, `breakdown` приложены).
- `skipped/provider_rejected|provider_timeout` — была реальная отправка (`simulated_result`), после
  которой заявка ушла дальше; `retries` в решении — число таких отправок.
- `selected/fallback_after_failure` — выбран после отказа предыдущего; `selected/fallback_self_provider` —
  внешних не осталось.
- `selected_provider: null`, `reason: no_eligible_provider` — никто не мог принять заявку (fallback
  отсутствует или сам не прошёл правила).

## Симуляция

`optimistic` — все отправки одобрены за `avg_latency_sec` провайдера; детерминировано, режим сдачи.
`conversion` — исход по `conversion_24h` с фиксированным `seed`; доля таймаутов среди неудач и их
задержка берутся из истории провайдера. Режим показывает каскад «отказ → следующий → fallback»
и используется в бенчмарке и what-if.

## Рекомендации

`Analytics::Recommendations::Engine` прогоняет 11 правил (`daily_limit_pressure`, `share_shortfall`,
`share_overflow`, `fallback_usage`, `amount_coverage_gap`, `low_conversion_overload`, `conversion_drift`,
`turnover_min_unmet`, `rate_limit_hits`, `in_progress_pressure`, `expired_heavy`). Каждое возвращает
`Recommendation(provider, severity, parameter, current, suggested, message)` — не «обратите внимание»,
а «поднять `limit_amount_max` у quickpay с 200000 до 250000».

## Как расширять

| Что | Где | Что сделать |
|---|---|---|
| Hard-правило | `lib/payout_router/constraints/` | наследник `Base#call(candidate, operation, now) → pass / violation(reason, details)`; код причины в `Routing::Reasons`; класс в `Registry::ALL`; ключ в `policy.yml` |
| Цель скоринга | `lib/payout_router/strategies/` | наследник `Base#evaluate(candidate, context) → signal(score, note)`; класс в `Registry::ALL`; вес в `goals` |
| Правило рекомендаций | `lib/payout_router/analytics/recommendations/` | наследник `Base#call(context) → [recommend(...)]`; класс в `Engine::RULES` |
| Параметр провайдера | `Domain::Provider` | поле в `Data.define` — его сразу можно задавать в `policy.yml → providers` |
| Режим симуляции | `lib/payout_router/simulation/` | класс с `call(candidate, operation) → Outcome`; ветка в `Simulation.build` |

## Производительность

Роутинг одной заявки — O(провайдеров × правил + провайдеров × целей + p log p); состояние обновляется
за O(1), очередь ответов — O(log n). На ноутбуке `rake bench` даёт ≈3 400 заявок/с через полный
конвейер с симуляцией отказов и построением объяснений; для CLI и бенчмарка классы загружаются
заранее (`PayoutRouter.eager_load!`), чтобы автозагрузка не попадала на горячий путь.

## Обработка ошибок

Входные файлы проверяются на границе (`Inputs::Fields`): отсутствующий файл, битый JSON/CSV/YAML,
неверный тип поля, отрицательная сумма, дубликаты `operation_id`/провайдеров, `limit_amount_min > max`,
неизвестные правила/цели/параметры в политике — `InputError`/`PolicyError` с точным адресом проблемы;
CLI печатает сообщение и завершается с кодом 2. Заявка без `created_at` получает время снимка (порядок
сохраняется), без банка — не проходит провайдеров с фильтром по банкам (`bank_unknown`). Отсутствие
fallback-провайдера — предупреждение, а не падение.
