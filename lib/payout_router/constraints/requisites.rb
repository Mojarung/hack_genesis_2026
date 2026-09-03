# frozen_string_literal: true

module PayoutRouter
  module Constraints
    # Свободные реквизиты/терминалы: каждая заявка в обработке занимает один.
    class Requisites < Base
      def call(candidate, _operation, _now)
        available = candidate.state.available_requisites
        return pass if available.positive?

        violation(Routing::Reasons::NO_AVAILABLE_REQUISITES, "available_requisites=#{available}")
      end
    end
  end
end
