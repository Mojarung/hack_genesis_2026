# frozen_string_literal: true

module PayoutRouter
  module Constraints
    class InProgressAmount < Base
      def call(candidate, operation, _now)
        limit = candidate.provider.in_progress_amount_limit
        return pass if limit.nil?

        amount = candidate.state.in_progress_amount
        return pass if amount + operation.amount <= limit

        violation(Routing::Reasons::IN_PROGRESS_AMOUNT_LIMIT,
                  "in_progress_amount #{amount} + #{operation.amount} > in_progress_amount_limit #{limit}")
      end
    end
  end
end
