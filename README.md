# PayoutRouter — умный роутинг выплат

Решение задачи 2 хакатона Hack.Genesis 2026: распределение выплат между платёжными
провайдерами с объяснением каждого решения, аналитикой качества роутинга и инструментами
«что-если». Ruby 4.0, без нейросетей и проприетарных компонентов.

На вход — состояние провайдеров (`providers.json`), очередь заявок и история операций.
На выход — `routing_decisions.json` (кому ушла каждая заявка, кого рассматривали, кого и
почему отсеяли), `routing_report.json` (распределение, загрузка лимитов, причины отсева,
рекомендации) и `routing_report.html` (дашборд одним файлом).

ТЗ: [docs/tz.md](docs/tz.md) · данные и их аудит: [docs/data.md](docs/data.md),
[docs/data_audit.md](docs/data_audit.md) · архитектура: [docs/architecture.md](docs/architecture.md) ·
питч: [docs/pitch.md](docs/pitch.md) · план: [docs/plan.md](docs/plan.md).
Каталог `analysis/` — офлайн-разведка данных на Python (polars), к решению не относится и в сборке
ответа не участвует; `scripts/history_stats.rb` — калибровка по истории на Ruby.

## Быстрый старт

```powershell
winget install --id RubyInstallerTeam.RubyWithDevKit.4.0 -e   # Ruby 4.0.6, один раз
bundle install
bundle exec rake            # тесты + линтер
bundle exec rake validate   # роутинг публичной очереди + автопроверка организаторов
```

Или в Docker: `docker build -t payout_router . && docker run --rm payout_router route`.

## Команды

`ruby -Ilib bin/payout_router <команда> --help` показывает опции. Общие: `--providers`, `--history`, `--policy`.

| Команда | Что делает |
|---|---|
| `route --queue Q --out DIR` | распределяет очередь → `routing_decisions.json`, `routing_report.json`, `routing_report.html` |
| `route --simulation conversion --seed 7` | исход каждой отправки разыгрывается по `conversion_24h`: виден каскад «отказ → следующий → fallback» |
| `explain OP_ID [--why-not P]` | разбор одной заявки: кого рассмотрели, кого выбрали, разложение скора по целям |
| `validate FILE --reference data/reference_decisions.json` | проверка файла решений: структура, покрытие, hard-правила, эталоны жюри |
| `backtest` | история организаторов через наш роутер: ожидаемые одобрения нашего роутинга против фактического |
| `compare [--policies a.yml b.yml]` | одна очередь, несколько политик: доли, отклонение, fallback, ожидаемые одобрения и маржа |
| `simulate --runs 200` | Monte-Carlo по отказам: перцентили одобрений, fallback и долей |
| `tune --synthetic 200` | подбор весов целей под бизнес-цель, результат в `policy_tuned.yml` |
| `serve --port 8080` | HTTP-сервис: `POST /route`, `GET /report`, `/state`, `/metrics` (Prometheus), `/health` |
| `strategies` | справочник: hard-правила, цели (встроенные, плагины, декларативные), пресеты политик |
| `history`, `bench` | показатели истории; 50 000 синтетических заявок через полный конвейер |

Сдача итоговых файлов: положить `operations_queue_test.json` в `data/`, выполнить `bundle exec rake submit`,
закоммитить `routing_decisions_test.json` и `routing_report_test.json` из корня в `main`.

## Как принимается решение

```
providers.json ─┐
queue.json ─────┼─► Inputs ─► для каждой заявки (по времени):
history.csv ────┘              1. Constraints  hard-правила: можно ли вообще отдать заявку провайдеру
policy.yml ────────────────►   2. Scoring      soft-goals: кого из допустимых предпочесть (взвешенный скор)
                               3. Routing      отправка лучшему; отказ/таймаут → следующий; пусто → fallback
                               4. State        оборот, in-progress, реквизиты, интенсивность, предохранитель
                             ─► routing_decisions.json + routing_report.json + routing_report.html
```

**Hard-constraints** (`config/policy.yml → hard_constraints`), 13 правил, каждое отдельным классом: статус,
валюта (заявка в USD не уйдёт в RUB-шлюз), `traffic_percentage > 0`, диапазон суммы, дневной лимит, in-progress
по количеству и сумме, реквизиты, маржа, фильтр банков, интенсивность (заявок в минуту), максимум оборота по
обязательству, предохранитель (серия отказов подряд → карантин). Провайдер, не прошедший хотя бы одно, попадает
в `attempts` как `skipped` с кодом причины и деталями (`"150000 > limit_amount_max 100000"`).

**Soft-goals** (`goals`), 12 стратегий с весами. Оценки разных целей живут в разных диапазонах (конверсии
0.79–0.91, доли 0–0.9), поэтому перед взвешиванием каждая цель приводится к разбросу среди кандидатов заявки
(`selection.normalization: pool`): лучший — 1, худший — 0, остальные пропорционально, все равны — 0.5. Тогда
вес означает ровно то, что написано: важность цели. Итоговый скор = Σ(вес × оценка по пулу) / Σ весов;
режим `absolute` оставляет оценки стратегий как есть.

| Стратегия из ТЗ | Цель в политике | Как считается |
|---|---|---|
| 1. Доля по количеству заявок | `traffic_share` | 0.5 + (цель − факт)/100: недобор поднимает, перебор опускает |
| 2. Доля по объёму | `volume_share` | то же по рублям; база — оборот дня из снимка + заявки сессии |
| 3. Очередь в каскаде | `cascade_priority` | первый по `priority` — 1.0, последний — 0.0 |
| 4. По сумме чека | `amount_band` | предпочтительный провайдер диапазона — 1.0, остальные — 0.0 |
| 5. По конверсии | `conversion` | `conversion_24h`, откалиброванная по истории: (одобрено + 10·заявленная)/(n + 10) |
| 6. По интенсивности | `rate_headroom` | запас по `requests_per_minute_limit` |
| 7. По фин. обязательствам | `turnover_min` (+ hard `daily_turnover_max`) | недобор до `daily_turnover_min` поднимает |
| — загрузка | `load` | 1 − худшая из загрузок лимитов (день, in-progress) |
| — сродство к банку | `bank_affinity` | конверсия пары провайдер × банк из истории (от 5 наблюдений), усаженная к провайдеру |
| — ожидаемая маржа | `expected_value` | конверсия × (маржа мерчанта − маржа провайдера) |
| — скорость, стоимость | `latency`, `margin` | быстрее и дешевле — выше |

**Два способа сочетать стратегии** (`selection.mode`):

- `weighted` — все цели одновременно, итог = взвешенная сумма; чистый каскад — `cascade_priority: 1.0`, остальное 0.
- `chain` — стратегии по очереди: следующая решает, только если предыдущая не применима к заявке (нет диапазона
  суммы, нет обязательства, нет истории) или дала равные оценки (в пределах `tolerance`). Шаг цепочки — одна
  стратегия или взвешенная группа. Победитель всегда лучший по решающему шагу, ранжирование полное, поэтому при
  отказе провайдера роутер идёт дальше по тому же списку. В `breakdown` каждого решения видно, какой шаг решил,
  какие «уступили», какие не консультировались.

```yaml
selection:
  mode: chain
  chain:
    - strategy: amount_band              # 1. по диапазону суммы
    - strategy: turnover_min             # 2. обязательство «не менее X ₽/сутки»
    - strategy: traffic_share            # 3. целевая доля; до 3 п.п. считаем равенством
      tolerance: 0.03
    - goals: { conversion: 0.5, bank_affinity: 0.5 }   # 4. кто вероятнее одобрит
    - strategy: cascade_priority         # 5. каскад
```

Пресеты в `config/policies/`: `cascade`, `conversion_first`, `profit_first`, `volume_balance`, `turnover_pressure`
(конфликт целей из ТЗ: максимум оборота одного против минимума другого), `strategy_chain`, `custom_strategy`;
`compare` прогоняет их все на одной очереди. При равном скоре порядок задают `tie_breakers`.
Если цель недостижима (провайдер с долей 40% не проходит фильтр банков), скорятся только допустимые, недобор
копится и отыгрывается на следующих заявках, а отчёт показывает достижимость цели и причину. Отчёт также
показывает, какие цели вообще различали кандидатов (`goal_activity`), и предлагает снять вес с мёртвой.

**Своя стратегия** добавляется без правки ядра, двумя способами:

1. Плагин на Ruby: файл с наследником `PayoutRouter::Strategies::Base` (один метод `evaluate`), строка
   `plugins: [config/plugins/my_strategy.rb]` в политике. Регистрируется автоматически, дальше используется в
   `goals` или в цепочке по ключу класса. Пример: `config/plugins/requisites_headroom.rb`.
2. Декларативная цель в YAML без кода (`custom_goals`): `field` (нормированное поле провайдера, `higher`/`lower`),
   `table` (оценки по провайдерам), `bank_table` (оценки провайдер × банк). Пример: `config/policies/custom_strategy.yml`.

Справочник всех правил, целей, декларативных типов и пресетов: `ruby -Ilib bin/payout_router strategies`.

**Fallback.** Отказ или таймаут провайдера — попытка помечается `skipped` с причиной `provider_rejected` /
`provider_timeout`, заявка уходит следующему по скору. Когда внешних не осталось — self-provider
(`spacepayments`). К нему применяются только статические правила допуска (статус, валюта, диапазон суммы, маржа,
банк; `fallback_constraints` в политике задаёт список явно, пустой — fallback безусловный): реквизиты, in-progress
и интенсивность self-provider не ограничивают, иначе плотная очередь оставила бы заявки без маршрута.
`selected_provider: null` возможен только если недоступен и fallback — наш `validate` считает это ошибкой,
как и скрипт организаторов. Три отказа подряд размыкают предохранитель: провайдер выбывает на `cooldown_sec`.

## Что-если и аналитика

- **Бэктест на истории.** 100 заявок организаторов прогоняются через роутер; вероятность одобрения — из
  `ApprovalModel` (заявленная конверсия → история провайдера → пара провайдер × банк, каждый уровень усаживает
  предыдущий) с leave-one-out: заявка не участвует в оценке самой себя. Политика `conversion_first` даёт
  **+4.7% ожидаемых одобрений** к фактическому роутингу; `balanced` — **−5.0%**: она держит доли партнёров
  (Σ|отклонение| 10 п.п. против 70 у `conversion_first`), и это цена обязательств, а не ошибка — `compare`
  показывает обе точки.
- **Сравнение политик, Monte-Carlo, подбор весов** — `compare`, `simulate`, `tune` (см. таблицу команд).
- **Рекомендации** с конкретным параметром и значением: 13 правил (дневной лимит, недостижимая доля, переток,
  fallback, разрыв по сумме, низкая конверсия, дрейф conversion_24h против истории, обязательство по обороту,
  интенсивность, лимиты обработки, таймауты, срабатывания предохранителя, мёртвая цель в скоринге).

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
и объёму), `skip_reasons`, `projected_daily_utilization`, `recommendations` — плюс `results` (исходы и конверсия
по провайдерам, срабатывания предохранителя), `attempts`, `target_attainability`, `history_analysis`
(включая конверсию по банкам и дрейф заявленной конверсии) и `recommendation_details`.

## Качество

- `bundle exec rspec` — 181 пример, покрытие строк 97.8%; интеграционные тесты гоняют скрипт организаторов, сверяют формат обоих файлов с образцом ТЗ поле за полем и пул допустимых с эталоном,
  регресс-тест на плотную очередь (все заявки в одну секунду) проверяет, что ни одна не остаётся без маршрута.
- `bundle exec rubocop` — без замечаний (Ruby 4.0, rubocop 1.90 + rubocop-rspec).
- `rake bench` — 50 000 заявок за ~15 с через полный конвейер с симуляцией отказов.
- CI (GitHub Actions): тесты, линтер, автопроверка организаторов, бэктест.

## Структура

```
bin/payout_router          CLI (Thor)
config/policy.yml          политика по умолчанию; config/policies/ — пресеты; config/plugins/ — пример своей стратегии
data/                      вводные организаторов
lib/payout_router/
  domain/                  Provider, Operation, Policy, Snapshot, HistoryRecord (неизменяемые Data)
  inputs/                  загрузчики JSON/CSV/YAML с проверкой полей
  constraints/             hard-правила (Base + 12 классов, Registry, Pipeline)
  strategies/              soft-goals (Base + 12 классов, Registry с плагинами, custom/ — декларативные цели)
  scoring/                 CompositeScorer (веса), ChainScorer (цепочка), TieBreaker, Score
  state/                   ProviderState, Ledger, SettlementQueue (виртуальные часы, предохранитель)
  routing/                 Router, BatchRouter, Attempt, Decision, Reasons
  simulation/              Optimistic, Conversion, Outcome
  analytics/               RoutingStats, HistoryStats, ApprovalModel, Backtest, PolicyComparison,
                           MonteCarlo, WeightTuner, ReportBuilder, recommendations/*
  validation/              DecisionsValidator (как у жюри + инварианты)
  output/                  JSONWriter, YAMLWriter, HtmlReport, Summary, Explanation, Tables
  server.rb                HTTP-сервис (WEBrick): /route, /report, /state, /metrics
  bench/                   генератор очереди и нагрузочный прогон
scripts/validate_10.rb     автопроверка организаторов
spec/                      RSpec
```
