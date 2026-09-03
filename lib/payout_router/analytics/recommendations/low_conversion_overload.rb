# frozen_string_literal: true

module PayoutRouter
  module Analytics
    module Recommendations
      # Провайдер с худшей конверсией получает больше цели — ожидаемые потери в одобрениях.
      class LowConversionOverload < Base
        THRESHOLD_PP = 5

        def call(context)
          providers = context.external
          return [] if providers.size < 2

          worst = providers.min_by { |provider| provider.conversion_24h.to_f }
          share = context.distribution[worst.name]
          return [] if share["deviation_pp"] < THRESHOLD_PP

          best = providers.map { |provider| provider.conversion_24h.to_f }.max
          [build(worst, share, best, context)]
        end

        private

        def build(worst, share, best, context)
          extra = (share["deviation_pp"] / 100.0 * context.total * (best - worst.conversion_24h.to_f)).round(1)
          weight = context.policy.goals.fetch("conversion", 0.0)
          recommend(
            provider: worst.name, severity: "info", parameter: "goals.conversion",
            current: weight, suggested: (weight + 0.1).round(2),
            message: "#{worst.name}: самая низкая конверсия в пуле (#{worst.conversion_24h}) при доле " \
                     "#{share["share_pct"]}% (цель #{share["target_pct"]}%) — примерно #{extra} лишних отказов на " \
                     "#{context.total} заявок. Поднять вес conversion с #{weight} до #{(weight + 0.1).round(2)} " \
                     "или расширить лимиты провайдеров с конверсией #{best}"
          )
        end
      end
    end
  end
end
