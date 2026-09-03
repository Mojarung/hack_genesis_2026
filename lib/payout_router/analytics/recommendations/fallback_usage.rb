# frozen_string_literal: true

module PayoutRouter
  module Analytics
    module Recommendations
      # Заявки уходят на self-provider — внешняя сеть не покрывает часть трафика.
      class FallbackUsage < Base
        CRITICAL_SHARE_PCT = 20

        def call(context)
          count = context.stats.fallback_count
          return [] if count.zero?

          reasons = Hash.new(0)
          context.stats.decisions.select(&:fallback_used).each do |decision|
            decision.attempts.select(&:hard_skip?).each { |attempt| reasons[attempt.reason] += 1 }
          end
          share = count * 100.0 / context.total
          top = reasons.sort_by { |_reason, n| -n }.first(3).map { |reason, n| "#{reason} ×#{n}" }
          [recommend(
            provider: context.policy.fallback_provider, severity: share >= CRITICAL_SHARE_PCT ? "critical" : "warning",
            parameter: "fallback_operations", current: count, suggested: 0,
            message: "#{count} из #{context.total} заявок (#{share.round(1)}%) ушли на self-provider " \
                     "#{context.policy.fallback_provider}: внешние провайдеры отсеяны по причинам " \
                     "#{top.join(", ")} — " \
                     "расширить лимиты/банки внешних провайдеров или подключить ещё одного"
          )]
        end
      end
    end
  end
end
