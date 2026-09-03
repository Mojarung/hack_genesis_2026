# frozen_string_literal: true

module PayoutRouter
  module Bench
    # Синтетическая очередь. По умолчанию суммы и банки — как в истории организаторов;
    # from_history сэмплирует реальные пары (сумма, банк) из записей истории.
    class QueueGenerator
      BANKS = %w[sberbank tinkoff vtb alfa raiffeisen gazprombank].freeze
      AMOUNTS = [800, 1_500, 2_000, 3_000, 5_000, 8_000, 10_000, 12_000, 15_000, 20_000, 25_000, 30_000,
                 35_000, 45_000, 48_000, 55_000, 75_000, 80_000, 95_000, 120_000, 150_000].freeze
      MAX_GAP_SEC = 5

      def self.from_history(records, seed:, start_at:)
        pairs = records.map { |record| [record.amount, record.bank] }
        new(seed: seed, start_at: start_at, pairs: pairs.empty? ? nil : pairs)
      end

      def initialize(seed:, start_at:, pairs: nil)
        @rng = Random.new(seed)
        @start_at = start_at
        @pairs = pairs
      end

      def generate(count)
        at = @start_at
        Array.new(count) do |index|
          at += 1 + @rng.rand(MAX_GAP_SEC)
          amount, bank = sample
          Domain::Operation.new(operation_id: "synthetic_#{index + 1}", created_at: at, amount: amount, bank: bank)
        end
      end

      private

      def sample
        return @pairs[@rng.rand(@pairs.size)] if @pairs

        [AMOUNTS[@rng.rand(AMOUNTS.size)], BANKS[@rng.rand(BANKS.size)]]
      end
    end
  end
end
