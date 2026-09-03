# frozen_string_literal: true

module PayoutRouter
  module Routing
    # Прогон очереди: заявки обрабатываются в хронологическом порядке (created_at),
    # чтобы лимиты интенсивности и in-progress считались честно; результат — в порядке входного файла.
    class BatchRouter
      Result = Data.define(:decisions, :ledger)

      def initialize(snapshot:, policy:, simulator:)
        @snapshot = snapshot
        @policy = policy
        @simulator = simulator
      end

      def call(operations)
        ledger = State::Ledger.new(@snapshot)
        router = Router.new(snapshot: @snapshot, policy: @policy, ledger: ledger, simulator: @simulator)
        decisions = Array.new(operations.size)
        chronological(operations).each { |index| decisions[index] = router.route(operations[index]) }
        ledger.settle_all
        Result.new(decisions: decisions, ledger: ledger)
      end

      private

      def chronological(operations) = operations.each_index.sort_by { |index| [operations[index].created_at, index] }
    end
  end
end
