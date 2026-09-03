# frozen_string_literal: true

module PayoutRouter
  module Constraints
    class AmountRange < Base
      def call(candidate, operation, _now)
        provider = candidate.provider
        amount = operation.amount
        if provider.limit_amount_min && amount < provider.limit_amount_min
          return violation(Routing::Reasons::AMOUNT_BELOW_MINIMUM,
                           "#{amount} < limit_amount_min #{provider.limit_amount_min}")
        end
        if provider.limit_amount_max && amount > provider.limit_amount_max
          return violation(Routing::Reasons::AMOUNT_EXCEEDS_LIMIT,
                           "#{amount} > limit_amount_max #{provider.limit_amount_max}")
        end

        pass
      end
    end
  end
end
