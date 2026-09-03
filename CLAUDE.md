# hack_genesis_2026 — карта проекта

Хакатон Hack.Genesis 2026 (основной этап 3–6 сентября 2026). Стек: Ruby 3.4,
зависимости через bundler. `ruby` на машине не в PATH сессии — в `C:\Ruby34-x64\bin`.

## Кейс: «Задача 2. Умный роутинг выплат»

ТЗ приехало 2026-09-03. На вход — очередь выплат и снапшот платёжных провайдеров,
на выход `routing_decisions_test.json` (кого выбрали, кого отсекли и почему) и
`routing_report_test.json` (аналитика + рекомендации), оба в корне ветки `main`.

- ТЗ: `docs/tz.md` (оригинал `docs/tz.docx`, картинки `docs/media/`)
- Данные: `data/`, короткая справка — `docs/data.md`
- **Аудит данных: `docs/data_audit.md`** — разбор файл за файлом, нестыковки,
  вопросы к организаторам, требования к архитектуре. Читать перед проектированием
- Валидатор организаторов: `scripts/validate_10.rb` (ищет `../data`, не двигать)
- Калибровка по истории: `scripts/history_stats.rb [--json]` → `data/derived/`
- Разведка на polars: `analysis/` (uv-проект, см. `analysis/README.md`).
  `analysis/paylens/rules.py` — реплика hard-фильтров валидатора, сверена
  с эталоном, расхождений 0; Ruby-реализация должна давать те же коды причин

Ограничения кейса: код преимущественно на Ruby, нейросети внутри решения
запрещены, проприетарные компоненты запрещены.

## Скелет paygen (написан до получения ТЗ)

Генератор интеграций из OpenAPI-спеки — отдельная от кейса вещь, к роутингу
отношения не имеет. Живой и зелёный, но под текущее ТЗ не переиспользуется.

## Пайплайн

```
SpecLoader → Analyzer → Generator
  файл       hash       IR::Api + ERB → файлы на диске
```

| Файл | Что делает | Якоря |
|---|---|---|
| `lib/paygen/spec_loader.rb` | читает YAML/JSON, разворачивает локальные `$ref`, обрывает циклы маркером `x-cycle` | `#resolve_hash` |
| `lib/paygen/analyzer.rb` | OpenAPI-hash → `IR::Api`: auth, base_url с подстановкой server variables, группировка операций по тегам | `#auth`, `#build_operation`, `#build_param` |
| `lib/paygen/ir.rb` | IR-структуры (`Api/Resource/Operation/Param/Body/Auth/Schema/Property`) + `IR.rubyize/classify` | — |
| `lib/paygen/generator.rb` | рендер шаблонов; `Generator::Context` — все хелперы для .erb (`signature`, `query_literal`, `sample_*`, `client_init`) | `#call` — список артефактов |
| `lib/paygen/cli.rb` | Thor: `generate`, `describe`, `version` | — |
| `lib/paygen/templates/` | .erb: `client/`, `docs/`, `tests/`, `project/` — исключены из rubocop | — |
| `fixtures/provider_api.yaml` | демо-спека Acme Pay: bearer, `$ref`, циклы, server variables, 5 операций / 2 тега | — |

## Правила

- Шаблоны не лезут в сырой OpenAPI-hash — только в IR. Новое поле нужно шаблону →
  сначала добавь его в IR и Analyzer.
- Новый артефакт на выходе = новый `.erb` + строка в `Generator#call`.
- Логика форматирования живёт в `Generator::Context`, а не внутри `.erb`.
- Две грабли Faraday, уже полечены в `client.rb.erb`: базовый URL с завершающим
  слешем и путь без ведущего — иначе `/v1` из базы теряется.
- `rubocop -a` на Windows переписывает файлы в CRLF. После автокоррекции гнать
  `sed -i 's/\r$//'`, в репозитории LF (`.gitattributes`).
- Проверка «всё живо» = сгенерировать демо и прогнать сгенерированные тесты:
  `ruby -Ilib bin/paygen generate fixtures/provider_api.yaml --out out/demo`,
  затем в `out/demo`: `bundle exec rspec`.

## Состояние

Скелет рабочий: 16 своих тестов + 10 сгенерированных зелёные, rubocop чистый.
Что не сделано — в конце `DEV.md`.
