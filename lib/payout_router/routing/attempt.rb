# frozen_string_literal: true

module PayoutRouter
  module Routing
    # Одна строка трейса решения: что случилось с провайдером при рассмотрении заявки.
    # Обязательные поля формата организаторов — provider, decision, reason; остальное — объяснение.
    class Attempt < Data.define(:provider, :decision, :reason, :details, :score, :breakdown,
                                :violations, :simulated_result, :latency_sec)
      SELECTED = "selected"
      SKIPPED = "skipped"

      def initialize(provider:, decision:, reason:, details: nil, score: nil, breakdown: nil,
                     violations: nil, simulated_result: nil, latency_sec: nil)
        super
      end

      def self.skipped(provider, reason, details = nil, **extra)
        new(provider: provider, decision: SKIPPED, reason: reason, details: details, **extra)
      end

      def self.selected(provider, reason, details = nil, **extra)
        new(provider: provider, decision: SELECTED, reason: reason, details: details, **extra)
      end

      def selected? = decision == SELECTED
      def skipped? = decision == SKIPPED

      # Была реальная отправка провайдеру (в отличие от отсева по правилам или скору).
      def dispatched? = !simulated_result.nil?

      def hard_skip? = Reasons::HARD.include?(reason)

      def serialize
        hash = { "provider" => provider, "decision" => decision, "reason" => reason }
        hash["details"] = details if details
        hash["score"] = score.round(4) if score
        hash["breakdown"] = breakdown if breakdown
        hash["violations"] = violations if violations && violations.size > 1
        hash["simulated_result"] = simulated_result if simulated_result
        hash["latency_sec"] = latency_sec if latency_sec
        hash
      end
    end
  end
end
