# frozen_string_literal: true

module PayoutRouter
  module Stress
    # Нарушенное свойство: что именно проверяли и что пошло не так.
    class Violation < Data.define(:rule, :detail)
      def to_s = "#{rule}: #{detail}"
    end
  end
end
