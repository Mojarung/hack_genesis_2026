# PayoutRouter — умный роутинг выплат

Решение задачи 2 хакатона Hack.Genesis 2026: распределение выплат между платёжными
провайдерами с объяснением каждого решения и аналитикой качества роутинга.

На вход — состояние провайдеров (`providers.json`), очередь заявок и история операций.
На выход — `routing_decisions.json` (кому ушла каждая заявка, кого рассматривали, кого и
почему отсеяли) и `routing_report.json` (распределение, загрузка лимитов, причины отсева,
рекомендации). Стек: Ruby 4.0, без нейросетей и проприетарных компонентов.

ТЗ: [docs/case/task.md](docs/case/task.md) · архитектура: [docs/architecture.md](docs/architecture.md) ·
план: [docs/plan.md](docs/plan.md).

## Быстрый старт

```powershell
winget install --id RubyInstallerTeam.RubyWithDevKit.4.0 -e   # Ruby 4.0.6, один раз
bundle install
bundle exec rake            # тесты + линтер
bundle exec rake validate   # роутинг публичной очереди + автопроверка организаторов
```

Основные команды (`ruby -Ilib bin/payout_router <команда> --help` покажет опции):

```powershell
# распределить очередь → out/routing_decisions.json + out/routing_report.json
ruby -Ilib bin/payout_router route --queue data/operations_queue_10.json --out out

# то же, но исход каждой отправки разыгрывается по conversion_24h (виден каскад при отказах)
ruby -Ilib bin/payout_router route --simulation conversion --seed 7 --out out/conv

# разбор одной заявки: кого рассмотрели, кого выбрали, разложение скора по целям
ruby -Ilib bin/payout_router explain op_103

# проверить файл решений: структура, покрытие очереди, hard-правила, эталоны организаторов
ruby -Ilib bin/payout_router validate out/routing_decisions.json --reference data/reference_decisions.json

# показатели истории операций / бенчмарк на 50 000 заявок
ruby -Ilib bin/payout_router history
ruby -Ilib bin/payout_router bench --operations 50000

# другая политика маршрутизации
ruby -Ilib bin/payout_router route --policy config/policies/cascade.yml --out out/cascade
```

## Сдача итоговых файлов

Положить `operations_queue_test.json` в `data/` и выполнить:

```powershell
bundle exec rake submit
```

В корне появятся `routing_decisions_test.json` и `routing_report_test.json`, сразу проверенные
валидатором. Закоммитить их в `main`.

## Как принимается решение

```
providers.json ─┐
queue.json ─────┼─► Inputs ─► для каждой заявки (по времени):
history.csv ────┘              1. Constraints  hard-правила: можно ли вообще отдать заявку провайдеру
policy.yml ────────────────►   2. Scoring      soft-goals: кого из допустимых предпочесть (взвешенный скор)
                               3. Routing      отправка лучшему; отказ/таймаут → следующий; пусто → fallback
                               4. State        обновление оборота, in-progress, реквизитов, интенсивности
                             ─► routing_decisions.json + routing_report.json (Analytics)
```

**Hard-constraints** (`config/policy.yml → hard_constraints`) — 11 правил, каждое отдельным классом:
статус, `traffic_percentage > 0`, диапазон суммы, дневной лимит, in-progress по количеству и сумме,
реквизиты, маржа, фильтр банков, интенсивность (заявок в минуту), максимум оборота по обязательству.
Провайдер, не прошедший хотя бы одно, попадает в `attempts` как `skipped` с кодом причины и деталями
(`"150000 > limit_amount_max 100000"`).

**Soft-goals** (`goals`) — 10 стратегий с весами; итоговый скор = Σ(вес × оценка 0..1) / Σ весов:

| Стратегия из ТЗ | Цель в политике | Как считается |
|---|---|---|
| 1. Доля по количеству заявок | `traffic_share` | 0.5 + (цель − факт)/100: недобор поднимает, перебор опускает |
| 2. Доля по объёму | `volume_share` | то же по рублям; база — оборот дня из снимка + заявки сессии |
| 3. Очередь в каскаде | `cascade_priority` | первый по `priority` — 1.0, последний — 0.0 |
| 4. По сумме чека | `amount_band` | предпочтительный провайдер диапазона — 1.0, остальные — 0.0 |
| 5. По конверсии | `conversion` | `conversion_24h` |
| 6. По интенсивности | `rate_headroom` | запас по `requests_per_minute_limit` |
| 7. По фин. обязательствам | `turnover_min` (+ hard `daily_turnover_max`) | недобор до `daily_turnover_min` поднимает |
| — загрузка | `load` | 1 − худшая из загрузок лимитов (день, in-progress) |
| — скорость, стоимость | `latency`, `margin` | быстрее и дешевле — выше (по умолчанию выключены) |

Комбинация стратегий — это веса; чистый каскад — `cascade_priority: 1.0`, остальное 0
(см. `config/policies/`). При равном скоре порядок задают `tie_breakers`. Если цель недостижима
(провайдер с долей 40% не проходит фильтр банков), скорятся только допустимые, недобор копится и
отыгрывается на следующих заявках, а отчёт показывает достижимость цели и причину.

**Fallback.** Отказ или таймаут провайдера (в режиме `conversion`) — попытка помечается `skipped` с
причиной `provider_rejected`/`provider_timeout`, заявка уходит следующему по скору. Когда внешних
не осталось — self-provider (`spacepayments`); если и он недоступен, `selected_provider: null` с причиной.

## Формат результата

`routing_decisions.json` — массив решений; обязательные поля организаторов плюс объяснение:

```json
{
  "operation_id": "op_101", "selected_provider": "vipay", "reason": "best_score",
  "attempts": [
    { "provider": "vipay", "decision": "selected", "reason": "best_score",
      "details": "score 0.6833; decisive: traffic_share (+0.27), conversion (+0.131)",
      "score": 0.6833, "breakdown": { "traffic_share": { "score": 0.9, "weight": 0.3, "weighted": 0.27,
      "note": "count share 0.0% vs target 40.0% (+40.0 pp)" }, "...": "..." },
      "simulated_result": "approved", "latency_sec": 38 },
    { "provider": "payflow", "decision": "skipped", "reason": "lower_score", "details": "score 0.6625 < 0.6833 (vipay)", "...": "..." },
    { "provider": "quickpay", "decision": "skipped", "reason": "amount_below_minimum", "details": "800 < limit_amount_min 1000" }
  ],
  "simulated_result": "approved", "latency_sec": 38, "amount": 15000, "bank": "sberbank",
  "created_at": "2026-07-30T09:05:00+03:00", "retries": 0, "fallback_used": false
}
```

`routing_report.json` — `period`, `total_operations`, `distribution` (доля/цель/отклонение по количеству
и объёму), `skip_reasons`, `projected_daily_utilization`, `recommendations` — плюс `results`
(approved/rejected/expired и конверсия по провайдерам), `attempts` (повторы, fallback),
`target_attainability` (в какой доле заявок провайдер вообще допустим и что его блокирует),
`history_analysis` (доли, конверсия, таймауты по истории, расхождение заявленной и наблюдаемой конверсии)
и `recommendation_details` — каждая рекомендация с правилом, провайдером, параметром и предлагаемым значением.

## Качество

- `bundle exec rspec` — 111 примеров, покрытие строк 98%; интеграционный тест гоняет скрипт организаторов.
- `bundle exec rubocop` — без замечаний (Ruby 4.0, rubocop 1.90 + rubocop-rspec).
- `rake bench` — 50 000 заявок за ~15 с (≈3 400 заявок/с) через полный конвейер с симуляцией отказов.

## Структура

```
bin/payout_router          CLI (Thor)
config/policy.yml          политика по умолчанию; config/policies/ — пресеты
data/                      вводные организаторов
lib/payout_router/
  domain/                  Provider, Operation, Policy, Snapshot, HistoryRecord (неизменяемые Data)
  inputs/                  загрузчики JSON/CSV/YAML с проверкой полей
  constraints/             hard-правила (Base + 11 классов, Registry, Pipeline)
  strategies/              soft-goals (Base + 10 классов, Registry)
  scoring/                 CompositeScorer, TieBreaker, Score
  state/                   ProviderState, Ledger, SettlementQueue (виртуальные часы)
  routing/                 Router, BatchRouter, Attempt, Decision, Reasons
  simulation/              Optimistic, Conversion, Outcome
  analytics/               RoutingStats, HistoryStats, ReportBuilder, recommendations/*
  validation/              DecisionsValidator (как у жюри + инварианты)
  output/                  JSONWriter, Summary, Explanation
  bench/                   генератор очереди и нагрузочный прогон
scripts/validate_10.rb     автопроверка организаторов
spec/                      RSpec
```
