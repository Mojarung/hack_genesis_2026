# frozen_string_literal: true

module PayoutRouter
  module Constraints
    # Итог одной hard-проверки. Успех — общий замороженный объект, без аллокаций на горячем пути.
    class Verdict < Data.define(:passed, :reason, :details)
      PASS = new(passed: true, reason: nil, details: nil)

      def self.violation(reason, details) = new(passed: false, reason: reason, details: details)

      def passed? = passed
    end
  end
end
