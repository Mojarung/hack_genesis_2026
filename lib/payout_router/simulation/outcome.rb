# frozen_string_literal: true

module PayoutRouter
  module Simulation
    # Ответ провайдера на отправленную заявку.
    class Outcome < Data.define(:result, :latency_sec)
      APPROVED = "approved"
      REJECTED = "rejected"
      EXPIRED = "expired"
      RESULTS = [APPROVED, REJECTED, EXPIRED].freeze

      def approved? = result == APPROVED
      def expired? = result == EXPIRED

      # Код причины для attempts, когда после такого ответа идём к следующему провайдеру.
      def failure_reason = expired? ? Routing::Reasons::PROVIDER_TIMEOUT : Routing::Reasons::PROVIDER_REJECTED
    end
  end
end
