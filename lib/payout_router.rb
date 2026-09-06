# frozen_string_literal: true

require "json"
require "time"
require "zeitwerk"
require_relative "payout_router/version"

loader = Zeitwerk::Loader.for_gem
loader.ignore("#{__dir__}/payout_router/version.rb")
loader.ignore("#{__dir__}/payout_router/templates")
loader.inflector.inflect("cli" => "CLI", "json_file" => "JSONFile", "json_writer" => "JSONWriter",
                         "yaml_writer" => "YAMLWriter")
loader.setup

# PayoutRouter — умный роутинг выплат между платёжными провайдерами.
#
# Конвейер одной заявки:
#   Inputs       файлы → доменные объекты (с проверкой формата)
#   Constraints  hard-constraints: можно ли вообще отдать заявку провайдеру
#   Scoring      soft-goals: кого из допустимых предпочесть (взвешенный скоринг)
#   Routing      попытки, отказ → следующий кандидат, fallback на self-provider, трейс решения
#   Simulation   исход попытки: approved / rejected / expired
#   Analytics    распределение, загрузка лимитов, рекомендации
module PayoutRouter
  class Error < StandardError; end

  # Некорректные входные данные: файл не найден, битый JSON/CSV, невалидные поля.
  class InputError < Error
    # true — ошибка относится к одной заявке очереди, и её можно увести в карантин
    # (--on-invalid skip). У «файл не найден» и «невалидный JSON» этот флаг не поднимается:
    # советовать там --on-invalid skip значит посылать по ложному следу.
    attr_accessor :skippable
  end

  # Ошибка в политике маршрутизации (config/policy.yml).
  class PolicyError < Error; end

  # Подгрузить все классы заранее: CLI и бенчмарк не должны платить за autoload на горячем пути.
  def self.eager_load! = Zeitwerk::Loader.eager_load_all
end
