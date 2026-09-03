# frozen_string_literal: true

module PayoutRouter
  module Strategies
    # Стратегия 1: целевая доля по числу заявок. Недобор поднимает оценку, перебор — опускает.
    # 0.5 — провайдер ровно на цели; каждые 10 п.п. отклонения сдвигают оценку на 0.1.
    class TrafficShare < Base
      def evaluate(candidate, context)
        target = candidate.provider.traffic_percentage.to_f
        actual = context.ledger.count_share_pct(candidate.state)
        deficit = target - actual
        signal(0.5 + (deficit / 100.0), "count share #{pct(actual)} vs target #{pct(target)} (#{signed(deficit)} pp)")
      end
    end
  end
end
