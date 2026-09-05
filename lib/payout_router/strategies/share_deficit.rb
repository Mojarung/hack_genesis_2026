# frozen_string_literal: true

module PayoutRouter
  module Strategies
    # Целевая доля по числу заявок, посчитанная в заявках, а не в процентах: сколько операций
    # провайдер недополучил к этому моменту — deficit = цель × (обработано + 1) − его заявки.
    #
    # Отличие от traffic_share принципиальное. Процентная разница одинаково оценивает 10 п.п.
    # на пятой заявке (половина операции — шум) и на пятисотой (полсотни операций — провал плана),
    # поэтому в начале очереди она дёргает выбор на пустом месте, а в конце уже не успевает
    # доехать до цели. Счётный недобор растёт вместе с очередью, и доли сходятся к цели,
    # а не «примерно к ней» — это классический deficit round-robin, только на допустимом пуле.
    class ShareDeficit < Base
      # Одна недополученная заявка — уже уверенный сигнал: tanh(1) ≈ 0.76.
      SCALE = 1.0

      def evaluate(candidate, context)
        target = target_share(candidate, context) { |item| item.provider.traffic_percentage.to_f }
        owed = target.pct / 100.0 * (context.ledger.selected_total + 1)
        have = candidate.state.selected_count
        deficit = owed - have
        signal(NEUTRAL + (NEUTRAL * Math.tanh(deficit / SCALE)),
               "owed #{format("%.2f", owed)} of #{context.ledger.selected_total + 1} ops, " \
               "routed #{have}#{target.note} (#{signed(deficit)})")
      end
    end
  end
end
