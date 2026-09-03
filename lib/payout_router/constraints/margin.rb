# frozen_string_literal: true

module PayoutRouter
  module Constraints
    class Margin < Base
      def call(candidate, _operation, _now)
        provider = candidate.provider
        return pass unless provider.negative_margin?

        violation(Routing::Reasons::NEGATIVE_MARGIN,
                  "provider_margin_pct #{provider.provider_margin_pct} > merchant_margin_pct " \
                  "#{provider.merchant_margin_pct}, allow_negative_agreement=false")
      end
    end
  end
end
