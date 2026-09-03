# frozen_string_literal: true

module PayoutRouter
  module Strategies
    # Ожидаемая маржа: вероятность одобрения × (маржа мерчанта − маржа провайдера).
    # Лучший по ожидаемой марже внешний провайдер получает 1.0, остальные — пропорционально.
    class ExpectedValue < Base
      def initialize(policy:, snapshot:, history: nil)
        super
        @best = snapshot.external.map { |provider| expected_margin(provider) }.max.to_f
      end

      def evaluate(candidate, _context)
        return signal(NEUTRAL, "no positive expected margin among providers") unless @best.positive?

        provider = candidate.provider
        value = expected_margin(provider)
        signal(value / @best,
               "expected margin #{format("%.3f", value)}% of amount " \
               "(conversion #{provider.conversion_24h} × margin #{format("%.2f", margin(provider))}%), " \
               "best #{format("%.3f", @best)}%")
      end

      private

      def margin(provider) = provider.merchant_margin_pct.to_f - provider.provider_margin_pct.to_f

      def expected_margin(provider) = provider.conversion_24h.to_f * margin(provider)
    end
  end
end
