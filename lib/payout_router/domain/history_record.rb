# frozen_string_literal: true

module PayoutRouter
  module Domain
    # Строка истории операций: куда ушла заявка и чем закончилась.
    class HistoryRecord < Data.define(:operation_id, :created_at, :amount, :bank, :card_brand,
                                      :provider, :status, :latency_sec)
      STATUSES = %w[approved rejected expired].freeze

      def initialize(operation_id:, amount:, provider:, status:, created_at: nil, bank: nil,
                     card_brand: nil, latency_sec: nil)
        super
      end

      def approved? = status == "approved"
      def rejected? = status == "rejected"
      def expired? = status == "expired"
    end
  end
end
