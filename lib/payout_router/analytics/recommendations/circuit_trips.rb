# frozen_string_literal: true

module PayoutRouter
  module Analytics
    module Recommendations
      # Провайдер уходил в карантин по предохранителю — серия отказов подряд, трафик терялся на повторах.
      class CircuitTrips < Base
        def call(context)
          context.external.filter_map do |provider|
            trips = context.stats.ledger.state(provider.name).circuit_trips
            next if trips.zero?

            breaker = context.policy.circuit_breaker
            recommend(
              provider: provider.name, severity: trips > 1 ? "critical" : "warning",
              parameter: "traffic_percentage", current: provider.traffic_percentage,
              suggested: [provider.traffic_percentage - 10, 0].max,
              message: "#{provider.name}: #{trips} раз уходил в карантин (#{breaker.failures} отказов подряд, " \
                       "пауза #{breaker.cooldown_sec} с) — снизить traffic_percentage " \
                       "с #{provider.traffic_percentage} до #{[provider.traffic_percentage - 10, 0].max} " \
                       "и разобраться с провайдером"
            )
          end
        end
      end
    end
  end
end
