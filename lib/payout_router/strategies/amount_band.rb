# frozen_string_literal: true

module PayoutRouter
  module Strategies
    # Стратегия 4: по сумме чека. Диапазон из политики влияет на выбор среди допустимых,
    # а не только отсекает (это делает hard-правило amount_range).
    #
    # Внутри диапазона предпочтительный провайдер получает 1, остальные 0. Если у диапазона задан
    # ramp, у его границ оценка плавно сходится к 0.5: на самой границе обе стороны равны,
    # и сумма в 50 001 ₽ не переворачивает решение относительно 49 999 ₽.
    class AmountBand < Base
      def evaluate(candidate, context)
        amount = context.operation.amount
        band = @policy.band_for(amount)
        return signal(NEUTRAL, "no amount band configured for #{amount}") if band.nil?

        preferred = band.prefer.include?(candidate.name)
        depth = band.depth(amount)
        note = if preferred then "preferred for amounts #{band.label}"
               else "amounts #{band.label} prefer #{band.prefer.join("/")}"
               end
        note += format(" (near edge: blend %.2f)", depth) if depth < 1.0
        signal(NEUTRAL + (((preferred ? 1.0 : 0.0) - NEUTRAL) * depth), note)
      end
    end
  end
end
