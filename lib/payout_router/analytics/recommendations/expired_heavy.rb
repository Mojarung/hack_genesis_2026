# frozen_string_literal: true

module PayoutRouter
  module Analytics
    module Recommendations
      # По истории у провайдера много таймаутов — деньги «зависают», клиенты ждут.
      class ExpiredHeavy < Base
        THRESHOLD = 0.15

        def call(context)
          return [] if context.history.empty?

          context.external.filter_map do |provider|
            stats = context.history.for(provider.name)
            next if stats.nil? || stats.expired_rate.nil? || stats.expired_rate < THRESHOLD

            weight = context.policy.goals.fetch("latency", 0.0)
            recommend(
              provider: provider.name, severity: "info", parameter: "goals.latency",
              current: weight, suggested: (weight + 0.1).round(2),
              message: "#{provider.name}: в истории #{(stats.expired_rate * 100).round(1)}% заявок " \
                       "истекли по таймауту " \
                       "(средняя задержка #{stats.avg_expired_latency&.round} с) — включить latency в скоринг " \
                       "(вес #{(weight + 0.1).round(2)}) или снизить traffic_percentage " \
                       "с #{provider.traffic_percentage} " \
                       "до #{[provider.traffic_percentage - 10, 0].max}"
            )
          end
        end
      end
    end
  end
end
