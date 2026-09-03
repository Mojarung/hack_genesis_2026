# frozen_string_literal: true

module PayoutRouter
  module Constraints
    # Результат прогона всех hard-правил по кандидату: список нарушений (пустой = допущен).
    class Evaluation < Data.define(:candidate, :violations)
      NONE = [].freeze

      def eligible? = violations.empty?
      def reason = violations.first&.reason
      def details = violations.first&.details
      def reasons = violations.map(&:reason)
    end
  end
end
