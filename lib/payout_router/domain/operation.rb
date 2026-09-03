# frozen_string_literal: true

module PayoutRouter
  module Domain
    # Заявка на выплату из очереди. bank — нормализованный код банка (нижний регистр).
    class Operation < Data.define(:operation_id, :created_at, :amount, :bank, :card_brand, :payout_requisite)
      def initialize(operation_id:, amount:, created_at: nil, bank: nil, card_brand: nil, payout_requisite: nil)
        super
      end
    end
  end
end
