# Ручная проверка: что запустить и что должно получиться

Все команды выполняются из корня репозитория. Перед началом один раз: `bundle install`.
Полная форма команды: `ruby -Ilib bin/payout_router <команда>`; ниже для краткости `pr` = `ruby -Ilib bin/payout_router`.

## 1. Всё живо (2 минуты)

| Команда | Что ожидать |
|---|---|
| `bundle exec rake` | 254 спека зелёные, RuboCop без замечаний |
| `bundle exec rake validate` | таблица распределения vipay 4 / payflow 3 / quickpay 3, затем скрипт организаторов: `Пройдено: 29, Ошибок: 0` и наш валидатор `ошибок 0` |
| `pr strategies` | 14 hard-правил, 13 целей, 3 декларативных типа, 10 пресетов |

## 2. Hard-constraints и объяснимость (критерии «корректность», «объяснимость»)

| Команда | Что ожидать |
|---|---|
| `pr explain op_103` | vipay и payflow `amount_exceeds_limit` с деталями `150000 > limit_amount_max ...`, quickpay `only_eligible_provider` с разложением скора |
| `pr explain op_104` | vipay и payflow `bank_not_in_list` (gazprombank), quickpay единственный допустимый |
| `pr explain op_107` | vipay и quickpay `amount_below_minimum` (800 < 1000), выбран payflow |
| `pr explain op_101` | все трое допустимы; vipay `best_score`, у остальных `lower_score` со сравнением скоров |
| `pr explain op_105 --why-not payflow` | одна строка: payflow отсеян по банку tinkoff |
| `pr explain op_101 --verbose` | разложение скора по всем целям для каждого кандидата |

Что показать в файле `routing_decisions.json`: у каждой попытки `reason` и `details`, у выбранного `score` и `breakdown`, порядок попыток = порядок рассмотрения.

## 3. Отказ → следующий провайдер → fallback (критерий «fallback»)

| Команда | Что ожидать |
|---|---|
| `pr route --simulation conversion --seed 7 --out out/conv` | в сводке `повторов после отказа: 1`; `pr explain op_105 --simulation conversion --seed 7` показывает vipay `provider_rejected` → quickpay `fallback_after_failure` |
| `pr simulate --runs 200` | перцентили: одобрено p5/p95, fallback до 2–4 в плохой прогон, доля spacepayments в среднем ~7% |
| `pr route --policy config/policies/cascade.yml --out out/cascade` | политика с симуляцией по conversion: видны `provider_rejected`/`provider_timeout` и переходы дальше по каскаду |

Предохранитель (серия отказов → карантин) покрыт спеком `spec/payout_router/constraints/circuit_breaker_spec.rb`; вручную его видно в `simulate` через `circuit_trips` в `out/simulation_report.json` при длинных прогонах или в `bench`.

## 4. Гибкость: стратегии, их сочетание, конфигурация (33 + 32 балла)

| Команда | Что ожидать |
|---|---|
| `pr compare` | одиннадцать политик на одной очереди с разным распределением, Σ отклонений, ожидаемыми одобрениями и маржой |
| `pr route --policy config/policies/strategy_chain.yml --out out/chain` и `pr explain op_101 --policy config/policies/strategy_chain.yml` | в breakdown шаги `1·amount_band` (decisive step) … `not consulted` |
| `pr explain op_105 --policy config/policies/strategy_chain.yml` | шаги 1 и 2 не различают vipay и quickpay (tie, passed to the next step), решает шаг 3 traffic_share |
| `pr route --policy config/policies/custom_strategy.yml --out out/custom` | работает плагин `requisites_headroom` и декларативные цели `fastest_first`, `q3_partner_deal`, `alfa_to_quickpay` |
| Поменять вес в `config/policy.yml` (например `conversion: 0.4`) и снова `pr route` | распределение меняется без правки кода |
| Поменять `traffic_percentage` в копии `data/providers.json` и передать `--providers` | доли следуют новым целям |
| `pr tune --synthetic 200 --candidates 60` | подобранные веса и целевая функция «до/после», файл `out/policy_tuned.yml`, который можно передать через `--policy` |

Своя стратегия за минуту: скопировать `config/plugins/requisites_headroom.rb`, переименовать класс, добавить `plugins:` и вес в политику, запустить `pr strategies` — новая цель в списке.

## 5. Обновление состояния провайдеров

| Команда | Что ожидать |
|---|---|
| `pr route` и открыть `out/routing_report.json` → `projected_daily_utilization` | payflow `utilization_pct` 99.6: после трёх заявок дневной лимит почти исчерпан |
| `pr explain op_110` | у payflow в `load` видна загрузка 98.3%; следующая заявка дороже остатка ушла бы другому (`daily_limit_exceeded`) |
| `pr serve` в одном терминале, в другом отправить одну заявку дважды: `Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8080/route -ContentType application/json -Body '{"operation_id":"x1","amount":15000,"bank":"sberbank"}'` и `Invoke-RestMethod http://127.0.0.1:8080/state` | `in_progress_count` у выбранного провайдера растёт между запросами; `/metrics` отдаёт `payout_router_*` |

## 6. Аналитика и рекомендации (10 + 11 баллов)

| Команда | Что ожидать |
|---|---|
| открыть `routing_report.html` в браузере | доли против целей, загрузка лимитов, причины отсева, достижимость целей, рекомендации, трейс каждой заявки |
| `pr history` | доли и конверсия по истории, конверсия по сумме чека (50–100 тыс. → 81%), интервалы Уилсона: у payflow заявленная 0.91 вне [0.273, 0.683] |
| `pr backtest --policy config/policies/conversion_first.yml` | ожидаемые одобрения: фактический роутинг 72.2, наш 75.6 (+4.7%) |
| `pr backtest` | политика balanced: 68.6 против факта 72.2 (−5.0%) — цена удержания долей, говорим сами |
| `pr backtest --policy config/policies/bank_affinity_first.yml` | 76.0 (+5.2%): пара «провайдер × банк» сильнее заявленной конверсии |
| `routing_report.json` → `examples` | четыре разобранных случая: `choice_among_several`, `single_eligible`, `retry_after_failure`, `fallback_to_self_provider`. У каждого — кто выбран, почему отсеяны остальные и `source` с файлом и методом |
| `routing_report.json` → `recommendations` | конкретные параметры: `payflow: дневной лимит 99.6% — снизить traffic_percentage с 35 до 20 или поднять daily_amount_limit до 3 800 000 ₽` |

## 7. Где предел: перебор конфигураций и эталон (доп. идеи, полнота)

| Команда | Что ожидать |
|---|---|
| `pr search --samples 60` | ~1 минута, около 2 000 конфигураций: граница Парето «отклонение против конверсии» и лидеры по каждой метрике. База `balanced` — на самой границе, доминирующих её конфигураций единицы и на уровне шума |
| `pr bound` | публичная очередь: наш роутинг 6.54 ожидаемых одобрения против оптимума 7.80 |
| `pr bound --synthetic 200 --seed 11` | 145.92 против 158.40 — на потоке берём 92–96% от всезнающего пакетного оптимума |
| `pr backtest --policy config/policies/bank_affinity_first.yml` | 76.0 (+5.2%) — пресет, найденный перебором |

Выводы и цифры целиком — `docs/search.md`; сверка с критериями трека — `docs/criteria.md`.

## 8. Ошибки и граничные случаи

| Команда | Что ожидать |
|---|---|
| `pr route --queue nope.json` | `ошибка: файл не найден`, код выхода 2 |
| очередь с `"amount": -5` | `ошибка: ... сумма должна быть положительной`, код 2 |
| политика с опечаткой `goals: { conversions: 1 }` | `неизвестная цель «conversions» (доступны: ...)` |
| очередь без `created_at` | заявки получают время снимка, порядок сохраняется |
| `--history ""` | без истории всё работает, `bank_affinity` нейтральна |

## 9. Производительность и сдача

| Команда | Что ожидать |
|---|---|
| `pr bench --operations 50000` | ≈5 с, ≈10 600 заявок/с на машине демо (на ноутбуке разработки ≈8.6 с, ≈5 800/с) |
| скопировать `data/operations_queue_10.json` в `data/operations_queue_test.json`, `bundle exec rake submit` | в корне `routing_decisions_test.json` и `routing_report_test.json`, валидатор 0 ошибок |
| `docker build -t payout_router . && docker run --rm payout_router route` | тот же результат без установленного Ruby |
