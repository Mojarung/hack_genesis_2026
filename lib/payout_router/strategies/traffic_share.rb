# frozen_string_literal: true

module PayoutRouter
  module Strategies
    # Стратегия 1: целевая доля по числу заявок. Недобор поднимает оценку, перебор — опускает.
    # 0.5 — провайдер ровно на цели; каждые 10 п.п. отклонения сдвигают оценку на 0.1.
    # При share_targets: attainable цель пересчитывается на допустимых кандидатов заявки (см. Base#target_share).
    class TrafficShare < Base
      def evaluate(candidate, context)
        target = target_share(candidate, context) { |item| item.provider.traffic_percentage.to_f }
        actual = context.ledger.count_share_pct(candidate.state)
        deficit = target.pct - actual
        signal(0.5 + (deficit / 100.0),
               "count share #{pct(actual)} vs target #{pct(target.pct)}#{target.note} (#{signed(deficit)} pp)")
      end
    end
  end
end
