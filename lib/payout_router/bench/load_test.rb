# frozen_string_literal: true

module PayoutRouter
  module Bench
    # Прогон полного конвейера на большой очереди. Лимиты провайдеров масштабируем под объём,
    # иначе через сотню заявок всё уходит в fallback и бенчмарк меряет только фильтр.
    class LoadTest
      Result = Data.define(:operations, :elapsed_sec, :ops_per_sec, :fallback, :retries)

      BASE_OPERATIONS = 100
      SCALED_LIMITS = %i[
        daily_amount_limit in_progress_count_limit in_progress_amount_limit
        available_requisites requests_per_minute_limit daily_turnover_max
      ].freeze

      def initialize(snapshot:, policy:)
        @snapshot = snapshot
        @policy = policy
      end

      def run(count, seed: 1)
        scaled = scale(@snapshot, [count / BASE_OPERATIONS, 1].max)
        operations = QueueGenerator.new(seed: seed, start_at: scaled.snapshot_at || Time.now).generate(count)
        simulator = Simulation.build(@policy.simulation.with(mode: "conversion", seed: seed))
        router = Routing::BatchRouter.new(snapshot: scaled, policy: @policy, simulator: simulator)

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = router.call(operations)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

        Result.new(operations: count, elapsed_sec: elapsed, ops_per_sec: count / elapsed,
                   fallback: result.decisions.count(&:fallback_used), retries: result.decisions.sum(&:retries))
      end

      private

      def scale(snapshot, factor)
        snapshot.with(providers: snapshot.providers.map do |provider|
          provider.with(**SCALED_LIMITS.to_h { |field| [field, scaled(provider.public_send(field), factor)] })
        end)
      end

      def scaled(value, factor) = value && (value * factor)
    end
  end
end
