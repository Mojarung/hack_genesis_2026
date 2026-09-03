# frozen_string_literal: true

module PayoutRouter
  module Domain
    # Провайдер выплат: снимок из providers.json плюс параметры, которых в снимке нет —
    # их задаёт политика (volume_share_pct, requests_per_minute_limit, daily_turnover_min/max, fallback).
    #
    # Объект неизменяемый — это конфигурация. Текущие счётчики (оборот, in-progress,
    # свободные реквизиты) живут в State::ProviderState и меняются по ходу роутинга.
    class Provider < Data.define(
      :name, :status, :traffic_percentage, :priority,
      :limit_amount_min, :limit_amount_max,
      :daily_amount_limit, :daily_approved_amount,
      :in_progress_count_limit, :in_progress_count,
      :in_progress_amount_limit, :in_progress_amount,
      :available_requisites, :conversion_24h, :avg_latency_sec,
      :banks, :exclude_banks,
      :provider_margin_pct, :merchant_margin_pct, :allow_negative_agreement,
      :volume_share_pct, :requests_per_minute_limit, :daily_turnover_min, :daily_turnover_max,
      :fallback
    )
      DEFAULT_PRIORITY = 1_000

      def initialize(volume_share_pct: nil, requests_per_minute_limit: nil, daily_turnover_min: nil,
                     daily_turnover_max: nil, fallback: false, banks: [], exclude_banks: false,
                     allow_negative_agreement: false, priority: DEFAULT_PRIORITY, **rest)
        super
      end

      def active? = status == "active"
      def fallback? = fallback == true
      def external? = !fallback?

      # Цель по объёму: если политика не задала — берём долю по количеству заявок.
      def volume_target_pct = volume_share_pct || traffic_percentage

      def negative_margin? = provider_margin_pct.to_f > merchant_margin_pct.to_f && !allow_negative_agreement

      def bank_filter? = !banks.empty?

      # Пустой список — любой банк; exclude_banks — список запрещённых, иначе — разрешённых.
      def bank_allowed?(bank)
        return true unless bank_filter?

        listed = banks.include?(bank)
        exclude_banks ? !listed : listed
      end
    end
  end
end
