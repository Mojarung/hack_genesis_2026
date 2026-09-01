# hack_genesis_2026 — карта проекта

Хакатон Hack.Genesis 2026 (основной этап 3–6 сентября 2026). Задача: генератор
интеграций с платёжными провайдерами — на вход OpenAPI-спека, на выход заготовка
клиента, документация и тесты. Стек: Ruby 3.4 + Thor + ERB, зависимости через bundler.

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
