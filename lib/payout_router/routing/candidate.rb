# frozen_string_literal: true

module PayoutRouter
  module Routing
    # Провайдер как кандидат на заявку. Конфигурацию читаем через состояние, а не копируем:
    # внешний снимок может обновить её посреди прогона (State::Ledger#sync!) — например,
    # провайдер выключился, — и кандидат должен видеть новую редакцию, а не ту, что была при старте.
    class Candidate < Data.define(:state)
      def provider = state.provider
      def name = provider.name
    end
  end
end
