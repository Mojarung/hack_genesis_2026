# frozen_string_literal: true

module PayoutRouter
  module Simulation
    # Исход по conversion_24h: с вероятностью conversion — approved, иначе rejected или expired.
    # Долю expired среди неудач и их задержку берём из истории операций провайдера,
    # если история есть. Seed делает прогон воспроизводимым.
    class Conversion
      DEFAULT_LATENCY_SEC = 30
      DEFAULT_EXPIRED_SHARE = 0.5
      DEFAULT_EXPIRED_LATENCY_SEC = 600

      attr_reader :seed

      def initialize(seed:, history_stats: nil)
        @seed = seed
        @rng = Random.new(seed)
        @history = history_stats
      end

      def mode = "conversion"

      def call(candidate, _operation)
        provider = candidate.provider
        latency = (provider.avg_latency_sec || DEFAULT_LATENCY_SEC).round
        return Outcome.new(result: Outcome::APPROVED, latency_sec: latency) if @rng.rand < provider.conversion_24h.to_f
        unless @rng.rand < expired_share(provider.name)
          return Outcome.new(result: Outcome::REJECTED,
                             latency_sec: latency)
        end

        Outcome.new(result: Outcome::EXPIRED, latency_sec: expired_latency(provider.name))
      end

      private

      def expired_share(name) = @history&.expired_share(name) || DEFAULT_EXPIRED_SHARE

      def expired_latency(name) = (@history&.avg_expired_latency(name) || DEFAULT_EXPIRED_LATENCY_SEC).round
    end
  end
end
