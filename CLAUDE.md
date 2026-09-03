# hack_genesis_2026 — карта проекта

Hack.Genesis 2026, задача 2 «Умный роутинг выплат» (основной этап 3–6 сентября 2026, ТЗ в
`docs/case/task.md`). Решение — гем `payout_router` на Ruby 4.0: hard-constraints → взвешенный
скоринг по soft-goals → каскад попыток с fallback → отчёт с рекомендациями. Нейросети в проекте
запрещены правилами кейса; почти весь код должен быть на Ruby.

## Окружение

- Ruby 4.0.6 стоит в `C:\Ruby40-x64` (winget `RubyInstallerTeam.RubyWithDevKit.4.0`); в новых
  терминалах он в PATH, в старых — `$env:PATH = "C:\Ruby40-x64\bin;" + $env:PATH`.
- Гемы в `vendor/bundle` (`bundle install`), запуск всего через `bundle exec`.
- `bundle exec rake` = rspec + rubocop. `rubocop -a` на Windows пишет CRLF — после автокоррекции
  прогнать `sed -i 's/\r$//'` по изменённым файлам; репозиторий в LF (`.gitattributes`).
- Рабочая ветка `kirill_backend2`, коммиты — conventional на русском, без co-author trailer.

## Пайплайн и якоря

| Слой | Файлы | Что искать |
|---|---|---|
| Входы | `lib/payout_router/inputs/*` | `Fields` — проверка полей с адресом ошибки; `PolicyLoader` валидирует ключи по реестрам |
| Домен | `lib/payout_router/domain/*` | `Provider` (Data + дефолты), `Policy#apply` накладывает overrides и fallback |
| Hard-правила | `lib/payout_router/constraints/*` | `Base#call → pass/violation`, `Registry::ALL`, `Pipeline#evaluate` собирает все нарушения |
| Состояние | `lib/payout_router/state/*` | `Ledger#dispatch!/settle_due` — виртуальные часы; `ProviderState#requests_within` — окно интенсивности |
| Цели | `lib/payout_router/strategies/*` | `Base#evaluate → signal(score, note)`, формула долей `0.5 + (цель − факт)/100` |
| Скоринг | `lib/payout_router/scoring/*` | `CompositeScorer#rank`, `TieBreaker#sort_key` |
| Роутинг | `lib/payout_router/routing/*` | `Router#route` → `try_ranked` → `fallback` → `unrouted`; коды причин в `Reasons` |
| Симуляция | `lib/payout_router/simulation/*` | `optimistic` (сдача) / `conversion` (seed, демо каскада) |
| Аналитика | `lib/payout_router/analytics/*` | `RoutingStats` (один проход), `ReportBuilder`, `recommendations/engine.rb` → `RULES` |
| Выход/CLI | `lib/payout_router/output/*`, `cli.rb`, `runner.rb` | `Runner#call` — весь сценарий; CLI только опции и печать |
| Проверка | `lib/payout_router/validation/decisions_validator.rb` | повторяет `scripts/validate_10.rb` + инвариант «один selected» |

## Правила

- Новая сущность = класс-наследник `Base` + строка в реестре + ключ в `config/policy.yml`. Логику
  в YAML не тащим, параметры в код — тоже.
- В `attempts` допустимы только `selected`/`skipped` (валидатор жюри); реальная отправка с отказом —
  `skipped` + `provider_rejected`/`provider_timeout` + `simulated_result`.
- Для сдачи используем `simulation.mode: optimistic`: эталонные кейсы жюри требуют единственного
  допустимого провайдера, случайные отказы их сломают.
- Проверка «всё живо»: `bundle exec rake validate` (роутинг публичной очереди + скрипт организаторов).
- Сдача: `operations_queue_test.json` в `data/`, `bundle exec rake submit`, файлы в корне `main`.

## Состояние

111 спеков зелёные (покрытие строк 98%), rubocop чист, бенчмарк ≈3 400 заявок/с. Дальнейшие шаги
по дням — `docs/plan.md`.
