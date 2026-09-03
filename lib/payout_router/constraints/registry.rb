# frozen_string_literal: true

module PayoutRouter
  module Constraints
    module Registry
      ALL = [
        ProviderActive, TrafficEnabled, AmountRange, DailyLimit, InProgressCount, InProgressAmount,
        Requisites, Margin, BankFilter, RateLimit, DailyTurnoverMax, CircuitBreaker
      ].freeze
      BY_KEY = ALL.to_h { |klass| [klass.key, klass] }.freeze

      def self.keys = BY_KEY.keys

      def self.fetch(key)
        BY_KEY.fetch(key) do
          raise PolicyError, "неизвестное hard-правило «#{key}» (доступны: #{keys.join(", ")})"
        end
      end
    end
  end
end
