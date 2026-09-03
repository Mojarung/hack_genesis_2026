# frozen_string_literal: true

module PayoutRouter
  module Domain
    # Заявка на выплату из очереди. bank — нормализованный код банка (нижний регистр),
    # currency — код валюты в верхнем регистре (nil = валюта шлюза).
    class Operation < Data.define(:operation_id, :created_at, :amount, :currency, :bank, :card_brand,
                                  :payout_requisite)
      def initialize(operation_id:, amount:, created_at: nil, currency: nil, bank: nil, card_brand: nil,
                     payout_requisite: nil)
        super
      end
    end
  end
end
