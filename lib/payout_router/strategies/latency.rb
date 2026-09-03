# frozen_string_literal: true

module PayoutRouter
  module Strategies
    # Предпочитать быстрых: самый медленный внешний провайдер получает 0, мгновенный — 1.
    class Latency < Base
      def initialize(policy:, snapshot:, history: nil)
        super
        @slowest = [snapshot.external.filter_map(&:avg_latency_sec).max || 1, 1].max.to_f
      end

      def evaluate(candidate, _context)
        latency = (candidate.provider.avg_latency_sec || @slowest).to_f
        signal(1.0 - (latency / @slowest), "avg_latency_sec #{latency.round} (slowest #{@slowest.round})")
      end
    end
  end
end
