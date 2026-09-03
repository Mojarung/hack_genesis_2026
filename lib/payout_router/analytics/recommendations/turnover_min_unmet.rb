# frozen_string_literal: true

module PayoutRouter
  module Analytics
    module Recommendations
      # Фин. обязательство «не менее X ₽/сутки» не выполнено по итогам прогона.
      class TurnoverMinUnmet < Base
        def call(context)
          context.external.filter_map do |provider|
            minimum = provider.daily_turnover_min
            next if minimum.nil? || minimum.zero?

            used = context.utilization[provider.name]["used"]
            next if used >= minimum

            weight = context.policy.goals.fetch("turnover_min", 0.0)
            recommend(
              provider: provider.name, severity: "warning", parameter: "goals.turnover_min",
              current: weight, suggested: [weight + 0.15, 0.3].min.round(2),
              message: "#{provider.name}: обязательство «не менее #{money(minimum)}/сутки» не выполнено — " \
                       "#{money(used)} (#{(used * 100.0 / minimum).round(1)}%). Поднять вес turnover_min с #{weight} " \
                       "до #{[weight + 0.15, 0.3].min.round(2)} или traffic_percentage " \
                       "с #{provider.traffic_percentage} " \
                       "до #{provider.traffic_percentage + 10}"
            )
          end
        end
      end
    end
  end
end
