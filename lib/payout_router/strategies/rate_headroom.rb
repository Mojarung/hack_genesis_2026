# frozen_string_literal: true

module PayoutRouter
  module Strategies
    # Стратегия 6: интенсивность. Чем ближе провайдер к лимиту заявок в минуту, тем ниже оценка.
    class RateHeadroom < Base
      def evaluate(candidate, context)
        limit = candidate.provider.requests_per_minute_limit
        return signal(1.0, "no requests_per_minute_limit") if limit.nil? || limit.zero?

        used = candidate.state.requests_within(context.now)
        signal(1.0 - (used.to_f / limit), "#{used}/#{limit} requests in last 60s")
      end
    end
  end
end
