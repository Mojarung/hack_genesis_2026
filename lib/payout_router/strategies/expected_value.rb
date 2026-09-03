# frozen_string_literal: true

module PayoutRouter
  module Strategies
    # Ожидаемая маржа: вероятность одобрения × (маржа мерчанта − маржа провайдера).
    # Вероятность — конверсия, откалиброванная по истории (как в цели conversion).
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
               "(conversion #{format("%.3f", conversion(provider))} × margin #{format("%.2f", margin(provider))}%), " \
               "best #{format("%.3f", @best)}%")
      end

      private

      def margin(provider) = provider.merchant_margin_pct.to_f - provider.provider_margin_pct.to_f

      def conversion(provider)
        approval_model&.probability(provider.name, nil) || provider.conversion_24h.to_f
      end

      def expected_margin(provider) = conversion(provider) * margin(provider)
    end
  end
end
