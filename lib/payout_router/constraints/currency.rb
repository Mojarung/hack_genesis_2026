# frozen_string_literal: true

module PayoutRouter
  module Constraints
    # Валюта заявки должна совпадать с валютой провайдера (у шлюза RUB_SBP_WITHDRAW это RUB).
    # Если у заявки или у провайдера валюта не задана — считаем, что она валюта шлюза, и пропускаем.
    class Currency < Base
      def call(candidate, operation, _now)
        expected = candidate.provider.currency
        actual = operation.currency
        return pass if expected.nil? || actual.nil? || expected == actual

        violation(Routing::Reasons::CURRENCY_MISMATCH, "#{actual} != provider currency #{expected}")
      end
    end
  end
end
