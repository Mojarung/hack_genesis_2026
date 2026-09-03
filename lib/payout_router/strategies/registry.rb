# frozen_string_literal: true

module PayoutRouter
  module Strategies
    module Registry
      ALL = [
        TrafficShare, VolumeShare, CascadePriority, AmountBand, Conversion, Load,
        TurnoverMin, RateHeadroom, Latency, Margin, BankAffinity, ExpectedValue
      ].freeze
      BY_KEY = ALL.to_h { |klass| [klass.key, klass] }.freeze

      def self.keys = BY_KEY.keys

      def self.fetch(key)
        BY_KEY.fetch(key) do
          raise PolicyError, "неизвестная цель «#{key}» (доступны: #{keys.join(", ")})"
        end
      end
    end
  end
end
