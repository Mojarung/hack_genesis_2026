# hack_genesis_2026 — карта проекта

Hack.Genesis 2026, задача 2 «Умный роутинг выплат» (основной этап 3–6 сентября 2026, ТЗ в
`docs/tz.md`). Решение — гем `payout_router` на Ruby 4.0: hard-constraints → взвешенный
скоринг по soft-goals → каскад попыток с fallback → отчёт с рекомендациями, плюс что-если анализ
и HTTP-сервис. Нейросети в проекте запрещены правилами кейса; почти весь код должен быть на Ruby.

## Окружение

- Ruby 4.0.6 стоит в `C:\Ruby40-x64` (winget `RubyInstallerTeam.RubyWithDevKit.4.0`); в новых
  терминалах он в PATH, в старых — `$env:PATH = "C:\Ruby40-x64\bin;" + $env:PATH`.
- Гемы в `vendor/bundle` (`bundle install`), запуск всего через `bundle exec`.
- `bundle exec rake` = rspec + rubocop. `rubocop -a` на Windows пишет CRLF — после автокоррекции
  прогнать `sed -i 's/\r$//'` по изменённым файлам; репозиторий в LF (`.gitattributes`).
- Рабочая ветка `kirill_backend2`, коммиты — conventional на русском, без co-author trailer; `main`
  обновляется fast-forward. `git push` из обычных команд виснет (sandbox), пушить фоновой командой.

## Пайплайн и якоря

| Слой | Файлы | Что искать |
|---|---|---|
| Входы | `lib/payout_router/inputs/*` | `Fields` — проверка полей с адресом ошибки; `PolicyLoader` валидирует ключи по реестрам |
| Домен | `lib/payout_router/domain/*` | `Provider` (Data + дефолты), `Policy#apply`, `Policy#with_goals`, `Policy#to_h_document` |
| Hard-правила | `lib/payout_router/constraints/*` | `Base#call → pass/violation`, `Registry::ALL` (13) и `Registry::STATIC` — правила для fallback; `CircuitBreaker` (со состоянием) |
| Состояние | `lib/payout_router/state/*` | `Ledger#dispatch!/settle_due` — виртуальные часы; `ProviderState#record_failure` — предохранитель |
| Цели | `lib/payout_router/strategies/*` | `Base#evaluate → signal(score, note)`, `Base#approval_model`; формула долей `0.5 + (цель − факт)/100`; `Conversion`/`BankAffinity`/`ExpectedValue` — через `Analytics::ApprovalModel` (усадка к приору, `MIN_BANK_SAMPLES = 5`) |
| Скоринг | `lib/payout_router/scoring/*` | `Scoring.build` → `CompositeScorer` (веса; `selection.normalization: pool` — min-max по пулу кандидатов, `absolute` — как есть) или `ChainScorer` (цепочка, всегда absolute); `Score#summary(versus:)` — решающие цели как перевес над соперником |
| Свои стратегии | `strategies/custom/*`, `config/plugins/*` | `Strategies.instantiate`; плагины регистрирует `Registry.discover!`; декларативные — `custom_goals` в YAML |
| Роутинг | `lib/payout_router/routing/*` | `Router#route` → `try_ranked` → `fallback` (только `policy.fallback_rules`, ёмкость self-provider не ограничивает) → `unrouted`; коды причин в `Reasons` |
| Симуляция | `lib/payout_router/simulation/*` | `optimistic` (сдача) / `conversion` (seed, демо каскада) |
| Аналитика | `lib/payout_router/analytics/*` | `ApprovalModel` (пара × банк, LOO), `Backtest`, `PolicyComparison`, `MonteCarlo`, `WeightTuner`, `recommendations/engine.rb` |
| Выход/CLI | `lib/payout_router/output/*`, `cli.rb`, `runner.rb`, `server.rb` | `Runner` — весь сценарий; `HtmlReport` + `templates/report.html.erb`; `Server::Service` |
| Проверка | `lib/payout_router/validation/decisions_validator.rb` | повторяет `scripts/validate_10.rb` + инвариант «один selected» |

## Правила

- Новая сущность = класс-наследник `Base` + строка в реестре + ключ в `config/policy.yml`.
- В `attempts` допустимы только `selected`/`skipped` (валидатор жюри); реальная отправка с отказом —
  `skipped` + `provider_rejected`/`provider_timeout` + `simulated_result`. `selected_provider: null` — ошибка
  в обоих валидаторах; регресс-тест на плотную очередь (`router_spec`) держит это.
- Для сдачи используем `simulation.mode: optimistic`; дефолтная политика `balanced` должна давать
  vipay 4 / payflow 3 / quickpay 3 на публичной очереди (спек `spec/integration`).
- Zeitwerk: аббревиатуры в именах файлов (`json_file`, `yaml_writer`) требуют инфлексии в `lib/payout_router.rb`;
  константы верхнего уровня — по одной на файл.
- Проверка «всё живо»: `bundle exec rake validate`. Сдача: `operations_queue_test.json` в `data/`,
  `bundle exec rake submit`, файлы в корне `main`.

## Состояние

181 спек зелёный (покрытие строк 97.8%), rubocop чист, бэктест conversion_first +4.7% / balanced −5.0% (цена
удержания долей), бенчмарк ≈3 400 заявок/с. Шпаргалка к чекпоинту — `docs/checkpoint.md`.
Дальнейшие шаги по дням — `docs/plan.md`, сценарий защиты — `docs/pitch.md`.
