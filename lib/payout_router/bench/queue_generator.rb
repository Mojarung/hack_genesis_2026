# frozen_string_literal: true

module PayoutRouter
  module Bench
    # Синтетическая очередь: суммы и банки — как в истории организаторов, интервалы 1–5 секунд.
    class QueueGenerator
      BANKS = %w[sberbank tinkoff vtb alfa raiffeisen gazprombank].freeze
      AMOUNTS = [800, 1_500, 2_000, 3_000, 5_000, 8_000, 10_000, 12_000, 15_000, 20_000, 25_000, 30_000,
                 35_000, 45_000, 48_000, 55_000, 75_000, 80_000, 95_000, 120_000, 150_000].freeze

      def initialize(seed:, start_at:)
        @rng = Random.new(seed)
        @start_at = start_at
      end

      def generate(count)
        at = @start_at
        Array.new(count) do |index|
          at += 1 + @rng.rand(5)
          Domain::Operation.new(operation_id: "bench_#{index + 1}", created_at: at,
                                amount: AMOUNTS[@rng.rand(AMOUNTS.size)], bank: BANKS[@rng.rand(BANKS.size)])
        end
      end
    end
  end
end
