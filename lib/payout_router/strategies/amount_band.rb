# frozen_string_literal: true

module PayoutRouter
  module Strategies
    # Стратегия 4: по сумме чека. Диапазон из политики влияет на выбор среди допустимых,
    # а не только отсекает (это делает hard-правило amount_range).
    class AmountBand < Base
      NEUTRAL = 0.5

      def evaluate(candidate, context)
        amount = context.operation.amount
        band = @policy.band_for(amount)
        return signal(NEUTRAL, "no amount band configured for #{amount}") if band.nil?
        return signal(1.0, "preferred for amounts #{band.label}") if band.prefer.include?(candidate.name)

        signal(0.0, "amounts #{band.label} prefer #{band.prefer.join("/")}")
      end
    end
  end
end
