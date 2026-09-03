# frozen_string_literal: true

module PayoutRouter
  module Constraints
    # Предохранитель: провайдер, выдавший серию отказов/таймаутов подряд, на время выбывает
    # из ротации — не жжём заявки и реквизиты на «лежащего» партнёра.
    class CircuitBreaker < Base
      def call(candidate, _operation, now)
        state = candidate.state
        return pass unless state.circuit_open?(now)

        violation(Routing::Reasons::CIRCUIT_OPEN,
                  "circuit open until #{state.circuit_open_until.strftime("%H:%M:%S")} after " \
                  "#{state.breaker.failures} consecutive failures (trip ##{state.circuit_trips})")
      end
    end
  end
end
