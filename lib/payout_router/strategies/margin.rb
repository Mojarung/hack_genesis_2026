# frozen_string_literal: true

module PayoutRouter
  module Strategies
    # Стоимость: чем меньше провайдер откусывает от маржи мерчанта, тем выше оценка.
    class Margin < Base
      NEUTRAL = 0.5

      def evaluate(candidate, _context)
        provider = candidate.provider
        merchant = provider.merchant_margin_pct.to_f
        return signal(NEUTRAL, "merchant_margin_pct not set") if merchant.zero?

        share = provider.provider_margin_pct.to_f / merchant
        signal(1.0 - share, "provider_margin #{provider.provider_margin_pct}% of merchant_margin #{merchant}%")
      end
    end
  end
end
