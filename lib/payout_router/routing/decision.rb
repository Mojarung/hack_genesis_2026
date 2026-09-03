# frozen_string_literal: true

module PayoutRouter
  module Routing
    # Итог роутинга одной заявки: кому ушла, чем закончилось и полный трейс рассмотрения.
    class Decision < Data.define(:operation, :selected_provider, :reason, :attempts, :simulated_result,
                                 :latency_sec, :retries, :fallback_used)
      def operation_id = operation.operation_id
      def routed? = !selected_provider.nil?
      def approved? = simulated_result == Simulation::Outcome::APPROVED
      def selected_attempt = attempts.find(&:selected?)

      def serialize
        {
          "operation_id" => operation_id,
          "selected_provider" => selected_provider,
          "reason" => reason,
          "attempts" => attempts.map(&:serialize),
          "simulated_result" => simulated_result,
          "latency_sec" => latency_sec,
          "amount" => operation.amount,
          "bank" => operation.bank,
          "created_at" => operation.created_at&.iso8601,
          "retries" => retries,
          "fallback_used" => fallback_used
        }
      end
    end
  end
end
