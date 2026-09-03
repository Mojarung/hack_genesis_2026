# frozen_string_literal: true

module PayoutRouter
  module Strategies
    # Стратегия 5: приоритет провайдерам с высокой конверсией за 24 часа.
    class Conversion < Base
      def evaluate(candidate, _context)
        conversion = candidate.provider.conversion_24h.to_f
        signal(conversion, "conversion_24h #{conversion}")
      end
    end
  end
end
