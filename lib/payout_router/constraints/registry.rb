# frozen_string_literal: true

module PayoutRouter
  module Constraints
    module Registry
      ALL = [
        ProviderActive, TrafficEnabled, AmountRange, DailyLimit, InProgressCount, InProgressAmount,
        Requisites, Margin, BankFilter, RateLimit, DailyTurnoverMax, CircuitBreaker
      ].freeze
      BY_KEY = ALL.to_h { |klass| [klass.key, klass] }.freeze

      DESCRIPTIONS = {
        "provider_active" => "status == active",
        "traffic_enabled" => "traffic_percentage > 0 (0 — провайдер выведен из ротации)",
        "amount_range" => "limit_amount_min <= amount <= limit_amount_max",
        "daily_limit" => "daily_approved_amount + amount <= daily_amount_limit",
        "in_progress_count" => "in_progress_count + 1 <= in_progress_count_limit",
        "in_progress_amount" => "in_progress_amount + amount <= in_progress_amount_limit",
        "requisites" => "available_requisites > 0",
        "margin" => "provider_margin_pct <= merchant_margin_pct или allow_negative_agreement",
        "bank_filter" => "банк заявки проходит banks / exclude_banks",
        "rate_limit" => "не больше requests_per_minute_limit отправок за скользящую минуту",
        "daily_turnover_max" => "оборот с учётом in-progress + amount <= daily_turnover_max",
        "circuit_breaker" => "провайдер не в карантине после серии отказов подряд"
      }.freeze

      def self.keys = BY_KEY.keys

      def self.describe(key) = DESCRIPTIONS.fetch(key, "")

      def self.fetch(key)
        BY_KEY.fetch(key) do
          raise PolicyError, "неизвестное hard-правило «#{key}» (доступны: #{keys.join(", ")})"
        end
      end
    end
  end
end
