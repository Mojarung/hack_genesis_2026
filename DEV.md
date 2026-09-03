# Окружение и запуск

## Что нужно на машине

```powershell
winget install --id RubyInstallerTeam.RubyWithDevKit.3.4 -e --silent
# перезапустить терминал, чтобы PATH подхватился
ruby -v      # ruby 3.4.x
gem install bundler   # обычно уже стоит
```

DevKit (MSYS2 + gcc) нужен для гемов с нативными расширениями — ставим сразу,
чтобы не ловить `failed to build gem native extension` посреди хакатона.

## Первый запуск

```powershell
bundle install
bundle exec rake        # тесты + линтер
```

## Генератор

```powershell
# посмотреть, что генератор вычитал из спеки
ruby -Ilib bin/paygen describe fixtures/provider_api.yaml

# сгенерировать интеграцию
ruby -Ilib bin/paygen generate fixtures/provider_api.yaml --out out/demo

# опции
#   -o, --out       каталог результата (по умолчанию out)
#   -n, --name      имя гема/модуля (по умолчанию из info.title)
#       --base-url  переопределить базовый URL (удобно для моков)
```

Проверить, что сгенерированное живое:

```powershell
cd out/demo
bundle install
bundle exec rspec
```

## Что сейчас умеет

- YAML и JSON, OpenAPI 3.x; локальные `$ref` разворачиваются, циклы (Payment ↔ Refund) обрываются;
- параметры уровня path-item наследуются операциями;
- серверные переменные (`https://api.{env}...`) подставляются дефолтами;
- securitySchemes → bearer / apiKey (header или query) / basic / oauth2;
- операции группируются по тегам → по классу-ресурсу на тег;
- на выходе: клиент на Faraday (ретраи, таймауты, типизированные ошибки,
  `Idempotency-Key` на POST/PATCH), README со справочником методов и моделей,
  RSpec-тесты на WebMock.

## Куда расти (это ещё не сделано)

- пагинация: курсор/offset определяются, но авто-итератора `each_page` нет;
- модели ответов: пока возвращаем `Hash`, схемы из `components` только в доках;
- вебхуки: подпись и верификация не генерируются;
- другие языки: шаблоны привязаны к Ruby, `templates/<lang>/` пока один;
- валидация спеки: падаем на кривом `$ref`, но полноценного линта OpenAPI нет.

## Кейс «Умный роутинг выплат»

Данные организаторов и ТЗ — см. `docs/data.md` и `docs/tz.md`. `ruby` в этой
машине лежит в `C:\Ruby34-x64\bin`; если PATH его не подхватил:

```powershell
$env:PATH = "C:\Ruby34-x64\bin;$env:PATH"
```

```powershell
# официальный валидатор организаторов — им будут проверять наш ответ
ruby scripts/validate_10.rb data/sample_routing_decisions.json

# калибровка по истории: доли count/volume, конверсия, латентность
ruby scripts/history_stats.rb           # сводка в stdout
ruby scripts/history_stats.rb --json    # + data/derived/history_stats.json
```

`scripts/validate_10.rb` ищет данные как `../data`, поэтому `scripts/` и `data/`
должны оставаться соседями в корне. Файл организаторский, из-под rubocop выведен.
