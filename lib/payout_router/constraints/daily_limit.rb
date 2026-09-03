# frozen_string_literal: true

module PayoutRouter
  module Constraints
    # Дневной максимум: одобренный оборот + сумма заявки не должны превысить daily_amount_limit.
    class DailyLimit < Base
      def call(candidate, operation, _now)
        limit = candidate.provider.daily_amount_limit
        return pass if limit.nil?

        used = candidate.state.daily_approved_amount
        return pass if used + operation.amount <= limit

        violation(Routing::Reasons::DAILY_LIMIT_EXCEEDED,
                  "daily_approved_amount #{used} + #{operation.amount} > daily_amount_limit #{limit}")
      end
    end
  end
end
