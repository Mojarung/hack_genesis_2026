# frozen_string_literal: true

module PayoutRouter
  module Stress
    # Один стресс-сценарий: подготовленный вход плюс то, что от него ожидается.
    #
    # expect_fallback_over / expect_unrouted и прочие ожидания намеренно НЕ живут здесь:
    # сценарий должен показывать, что происходит на самом деле, а не подтверждать заранее
    # написанный ответ. Жёстко проверяются только инварианты (Stress::Invariants),
    # всё остальное измеряется и печатается.
    Scenario = Data.define(:key, :title, :note, :snapshot, :operations, :policy, :simulator,
                           :allow_unrouted, :before_each) do
      def initialize(note: nil, allow_unrouted: false, before_each: nil, **rest) = super

      def size = operations.size
    end
  end
end
