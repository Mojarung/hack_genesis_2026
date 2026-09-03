# frozen_string_literal: true

module PayoutRouter
  module Analytics
    module Recommendations
      # Провайдер близок к дневному лимиту оборота: скоро начнёт отваливаться по hard-правилу.
      class DailyLimitPressure < Base
        WARNING_PCT = 85
        CRITICAL_PCT = 95

        def call(context)
          context.external.filter_map do |provider|
            usage = context.utilization[provider.name]
            pct = usage["utilization_pct"]
            next if pct.nil? || pct < WARNING_PCT

            build(provider, usage, pct)
          end
        end

        private

        def build(provider, usage, pct)
          target = provider.traffic_percentage
          suggested_traffic = [round_to(target / 2.0, 5), 5].max
          suggested_limit = ceil_to(usage["used"] * 1.25, 100_000)
          recommend(
            provider: provider.name, severity: pct >= CRITICAL_PCT ? "critical" : "warning",
            parameter: "traffic_percentage", current: target, suggested: suggested_traffic,
            message: "#{provider.name}: дневной лимит использован на #{pct}% (#{money(usage["used"])} из " \
                     "#{money(usage["limit"])}) — снизить traffic_percentage с #{target} до #{suggested_traffic} " \
                     "или поднять daily_amount_limit до #{money(suggested_limit)}"
          )
        end
      end
    end
  end
end
