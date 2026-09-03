# frozen_string_literal: true

module PayoutRouter
  module Constraints
    # Фин. обязательство «не более X ₽ в сутки». Считаем с учётом заявок, которые ещё в обработке:
    # они почти наверняка станут оборотом, а перебор обязательства дороже недобора.
    class DailyTurnoverMax < Base
      def call(candidate, operation, _now)
        max = candidate.provider.daily_turnover_max
        return pass if max.nil?

        projected = candidate.state.volume_in_flight
        return pass if projected + operation.amount <= max

        violation(Routing::Reasons::DAILY_TURNOVER_MAX_EXCEEDED,
                  "projected turnover #{projected} + #{operation.amount} > daily_turnover_max #{max}")
      end
    end
  end
end
