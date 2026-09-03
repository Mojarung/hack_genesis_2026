# frozen_string_literal: true

module PayoutRouter
  module Routing
    # Провайдер как кандидат на заявку: неизменяемая конфигурация + текущее состояние.
    class Candidate < Data.define(:provider, :state)
      def name = provider.name
    end
  end
end
