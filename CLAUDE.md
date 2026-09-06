# hack_genesis_2026 — карта проекта

Hack.Genesis 2026, задача 2 «Умный роутинг выплат» (основной этап 3–6 сентября 2026, ТЗ в
`docs/tz.md`). Решение — гем `payout_router` на Ruby 4.0: hard-constraints → взвешенный
скоринг по soft-goals → каскад попыток с fallback → отчёт с рекомендациями, плюс что-если анализ
и HTTP-сервис. Нейросети в проекте запрещены правилами кейса; почти весь код должен быть на Ruby.

## Окружение

- Ruby 4.0.6 + DevKit стоит в `C:\Ruby40-x64`, ставится с `nomodpath` — в системном PATH его нет,
  поэтому каждую сессию первой строкой: `$env:PATH = "C:\Ruby40-x64\bin;" + $env:PATH`. Без неё
  `bundle` либо не найдётся вовсе, либо (если в PATH вернётся Ruby 3.4) упадёт на
  `Bundler::RubyVersionMismatch`.
- Через `winget` установка виснет без вывода. Рабочий путь — тихая установка инсталлятора:
  скачать `rubyinstaller-devkit-4.0.6-1-x64.exe` из релизов `oneclick/rubyinstaller2` и запустить
  с `/verysilent /norestart /currentuser /dir=C:\Ruby40-x64 /tasks=noassocfiles,nomodpath,noridkinstall`.
  DevKit обязателен: `racc`, `json` и `prism` из `Gemfile.lock` собираются нативно, портативная
  7z-сборка без MSYS-`make` на них падает.
- Совместимость с Ruby 3.x **не нужна** — эксперты разрешили 4.0, Gemfile держит `~> 4.0`.
  Чистая копия проверяется в Docker `ruby:4.0` (там же включается YJIT).
- Запускать Ruby **через PowerShell**: из Git Bash `ruby.exe` падает на `api-ms-win-crt-*.dll`
  (в MSYS-окружении нет системного PATH к UCRT).
- Эта сборка Ruby собрана **без YJIT** (`RubyVM::YJIT` не определён); `bin/payout_router` включает его
  по факту наличия, так что в Docker (`ruby:4.0`) он работает, локально — нет.
- Гемы в `vendor/bundle` (`bundle install`), запуск всего через `bundle exec`.
- `bundle exec rake` = rspec + rubocop. `rubocop -a` на Windows пишет CRLF — после автокоррекции
  прогнать `sed -i 's/\r$//'` по изменённым файлам; репозиторий в LF (`.gitattributes`).
- Задача = ветка от `main` (`feat/` · `fix/` · `docs/` · `chore/`), PR, squash-merge; напрямую в `main`
  не коммитим. Коммиты — conventional на русском. `git push` из обычных команд виснет (sandbox),
  пушить фоновой командой.

## Пайплайн и якоря

| Слой | Файлы | Что искать |
|---|---|---|
| Входы | `lib/payout_router/inputs/*` | `Fields` — проверка полей с адресом ошибки; `PolicyLoader` валидирует ключи по реестрам; `QueueLoader#on_invalid: :skip` — карантин битых заявок; `StateUpdate` — внешний снимок состояния |
| Домен | `lib/payout_router/domain/*` | `Provider` (Data + дефолты), `Policy#apply`, `Policy#with_goals`, `Policy#to_h_document` |
| Hard-правила | `lib/payout_router/constraints/*` | `Base#call → pass/violation`, `Registry::ALL` (14) и `Registry::STATIC` — правила для fallback; `CircuitBreaker` (со состоянием); `DailyLimitReserved` — строгий дневной лимит, по умолчанию выключен (формула ТЗ в `DailyLimit`) |
| Состояние | `lib/payout_router/state/*` | `Ledger#dispatch!/settle_due` — виртуальные часы и точка линеаризации; `Ledger#sync!` — внешний снимок перед заявкой (`Inputs::StateUpdate`); `ProviderState#record_failure` — предохранитель; `#hold_timeout!` — таймаут без освобождения ёмкости |
| Перебор | `lib/payout_router/search/*` | `Battery` — очереди + бэктест для всех кандидатов; `Space.structural` — 12 вариантов (нормировка × доли × дневной лимит); `Front#add?` — инкрементальная граница Парето; `Engine` — сетка + случайные точки + доводка. CLI `search`, выводы — `docs/search.md` |
| Эталон | `lib/payout_router/analytics/assignment_bound.rb` | оптимальное распределение очереди как транспортная задача (`MinCostFlow`), CLI `bound`: наш роутинг против всезнающего оптимума. Self-provider доступен эталону ровно в том объёме, в каком его использовал роутер, — иначе задача вырождается в «всё себе» |
| Цели | `lib/payout_router/strategies/*` | `Base#evaluate → signal(score, note)`, `Base#approval_model`; формула долей `0.5 + (цель − факт)/100`; `Base#target_share` — перенормировка цели на допустимых (`share_targets: attainable`); `Conversion`/`BankAffinity`/`ExpectedValue` — через `Analytics::ApprovalModel` (усадка к приору, `MIN_BANK_SAMPLES = 5`); `ShareDeficit` — доли в заявках (deficit round-robin), по умолчанию вес 0 |
| Скоринг | `lib/payout_router/scoring/*` | `Scoring.build` → `CompositeScorer` (веса; `selection.normalization: pool` — min-max по пулу кандидатов, `absolute` — как есть, `damped` — pool с добавкой к разбросу) или `ChainScorer` (цепочка, всегда absolute); `Score#summary(versus:)` — решающие цели как перевес над соперником |
| Свои стратегии | `strategies/custom/*`, `config/plugins/*` | `Strategies.instantiate`; плагины регистрирует `Registry.discover!`; декларативные — `custom_goals` в YAML |
| Роутинг | `lib/payout_router/routing/*` | `Router#route` → `try_ranked` → `fallback` (только `policy.fallback_rules`, ёмкость self-provider не ограничивает) → `unrouted`; коды причин в `Reasons` |
| Симуляция | `lib/payout_router/simulation/*` | `optimistic` (сдача) / `conversion` (seed, демо каскада); `simulation.timeout: cascade\|hold` — семантика таймаута (ТЗ против разъяснения экспертов), флаг `--timeout` |
| Аналитика | `lib/payout_router/analytics/*` | `ApprovalModel` (пара × банк, LOO), `Backtest`, `PolicyComparison`, `MonteCarlo`, `WeightTuner`, `recommendations/engine.rb`; `RoutingStats#accumulate_fair_share` — достижимая цель (`proportional_target_pct`); `CascadeDemo` — каскад с отказами в отчёте при optimistic-прогоне |
| Выход/CLI | `lib/payout_router/output/*`, `cli.rb`, `runner.rb`, `server.rb` | `Runner` — весь сценарий; `HtmlReport` + `templates/report.html.erb`; `Server::Service` |
| Проверка | `lib/payout_router/validation/decisions_validator.rb` | повторяет `scripts/validate_10.rb` + инвариант «один selected» |
| Стресс | `lib/payout_router/stress/*` | `Catalog::ORDER` — 17 сценариев; `Invariants` — жёсткие проверки (сохранение ёмкости, пики, трейс); `Oracles` — пересчёт допустимости и интенсивности заново по решениям; `Suite` → `Outcome` — метрики без порогов; `rake stress` |

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
- Дефолтную политику не трогать: перебор 113 000 конфигураций показал, что `balanced` уже
  на границе Парето (`docs/search.md`). Улучшать есть смысл только входные данные, а не веса.
- Цифры в доках держать сверенными с прогоном: `rake` (спеки, покрытие), `strategies` (14 правил,
  13 целей, 10 пресетов), `bench`, `backtest`. Расхождение эксперт увидит за минуту.
- Новую проверку в `spec/integration/stress_spec.rb` принимаем только после мутации: внести
  в код настоящую ошибку и убедиться, что тест падает. Проверки, читающие счётчики роутера,
  мутаций не ловят — оракулы считают заново по решениям и снимку (`Stress::Oracles`).

## Состояние

244 спека зелёные (покрытие строк 96.2%, ветви 80.3%), rubocop чист, чистая копия в Docker `ruby:4.0` проходит всё (с YJIT ≈3 300 заявок/с), `rake stress` — 17 сценариев и ~16 000 заявок
с нулём нарушений инвариантов, бэктест conversion_first +4.7% / balanced −5.0% (цена удержания долей),
бенчмарк ≈10 600 заявок/с на Ryzen 7 9700X и ≈5 800 на ноутбуке разработки (оба без YJIT), деградации на объёме нет: 200 000 заявок идут с той же скоростью, что 5 000. Разбор QA-сессии и чекпоинта 1 (оба 04.09) —
`docs/checkpoint.md`, разделы 4.3–4.5. Ответы экспертов закрыли почти всё: доля по количеству —
от заявок прогона, доля по деньгам — оборот дня плюс прогон, таймаут — отдельный кейс на наше
усмотрение, провайдеры одним JSON, кастомные поля в отчёте можно, валюта одна, важны и доли,
и одобрения. Открытые вопросы к жюри — шесть, раздел 5: резервировать ли дневной лимит под in-progress,
показывать ли отказы в сдаваемом файле, как проверяют отчёт, что считается «поведением при
невыполнимой цели», как мерить успешность, какие входы будут к тестовой очереди.
Сверка с критериями трека — `docs/criteria.md`, выводы перебора — `docs/search.md`,
шаги по дням — `docs/plan.md`, сценарий защиты — `docs/pitch.md`.
