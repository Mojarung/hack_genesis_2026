# frozen_string_literal: true

module PayoutRouter
  module Simulation
    # Все заявки одобрены за среднее время ответа провайдера. Без случайности —
    # результат воспроизводим и проверяем автотестом организаторов.
    class Optimistic
      DEFAULT_LATENCY_SEC = 30

      def mode = "optimistic"

      def call(candidate, _operation)
        Outcome.new(result: Outcome::APPROVED,
                    latency_sec: (candidate.provider.avg_latency_sec || DEFAULT_LATENCY_SEC).round)
      end
    end
  end
end
