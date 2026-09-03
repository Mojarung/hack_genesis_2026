# frozen_string_literal: true

module PayoutRouter
  module Routing
    # Коды причин в attempts. Единственное место, где они определены:
    # по ним же строятся отчёт (skip_reasons) и объяснения в CLI.
    module Reasons
      # Hard-constraints: провайдер не допущен к заявке.
      PROVIDER_INACTIVE = "provider_inactive"
      TRAFFIC_DISABLED = "traffic_disabled"
      AMOUNT_BELOW_MINIMUM = "amount_below_minimum"
      AMOUNT_EXCEEDS_LIMIT = "amount_exceeds_limit"
      DAILY_LIMIT_EXCEEDED = "daily_limit_exceeded"
      IN_PROGRESS_COUNT_LIMIT = "in_progress_count_limit_reached"
      IN_PROGRESS_AMOUNT_LIMIT = "in_progress_amount_limit_exceeded"
      NO_AVAILABLE_REQUISITES = "no_available_requisites"
      NEGATIVE_MARGIN = "negative_margin"
      BANK_NOT_IN_LIST = "bank_not_in_list"
      BANK_EXCLUDED = "bank_excluded"
      BANK_UNKNOWN = "bank_unknown"
      RATE_LIMIT_EXCEEDED = "rate_limit_exceeded"
      DAILY_TURNOVER_MAX_EXCEEDED = "daily_turnover_max_exceeded"

      # Результат выбора среди допустимых.
      BEST_SCORE = "best_score"
      ONLY_ELIGIBLE = "only_eligible_provider"
      LOWER_SCORE = "lower_score"

      # Попытка отправки не удалась → переход к следующему.
      PROVIDER_REJECTED = "provider_rejected"
      PROVIDER_TIMEOUT = "provider_timeout"
      FALLBACK_AFTER_FAILURE = "fallback_after_failure"
      FALLBACK_SELF_PROVIDER = "fallback_self_provider"
      NO_ELIGIBLE_PROVIDER = "no_eligible_provider"

      HARD = [
        PROVIDER_INACTIVE, TRAFFIC_DISABLED, AMOUNT_BELOW_MINIMUM, AMOUNT_EXCEEDS_LIMIT, DAILY_LIMIT_EXCEEDED,
        IN_PROGRESS_COUNT_LIMIT, IN_PROGRESS_AMOUNT_LIMIT, NO_AVAILABLE_REQUISITES, NEGATIVE_MARGIN,
        BANK_NOT_IN_LIST, BANK_EXCLUDED, BANK_UNKNOWN, RATE_LIMIT_EXCEEDED, DAILY_TURNOVER_MAX_EXCEEDED
      ].freeze

      FAILURES = [PROVIDER_REJECTED, PROVIDER_TIMEOUT].freeze

      DESCRIPTIONS = {
        PROVIDER_INACTIVE => "провайдер не в статусе active",
        TRAFFIC_DISABLED => "целевая доля трафика 0% — провайдер выключен из ротации",
        AMOUNT_BELOW_MINIMUM => "сумма меньше минимального чека",
        AMOUNT_EXCEEDS_LIMIT => "сумма больше максимального чека",
        DAILY_LIMIT_EXCEEDED => "исчерпан дневной лимит оборота",
        IN_PROGRESS_COUNT_LIMIT => "достигнут лимит одновременных заявок",
        IN_PROGRESS_AMOUNT_LIMIT => "достигнут лимит суммы заявок в обработке",
        NO_AVAILABLE_REQUISITES => "нет свободных реквизитов",
        NEGATIVE_MARGIN => "маржа провайдера выше маржи мерчанта без соглашения",
        BANK_NOT_IN_LIST => "банк получателя не в списке поддерживаемых",
        BANK_EXCLUDED => "банк получателя в списке исключений",
        BANK_UNKNOWN => "банк не указан, а у провайдера есть фильтр по банкам",
        RATE_LIMIT_EXCEEDED => "превышена интенсивность (заявок в минуту)",
        DAILY_TURNOVER_MAX_EXCEEDED => "достигнут максимум оборота по фин. обязательству",
        BEST_SCORE => "лучший суммарный скор по активным целям",
        ONLY_ELIGIBLE => "единственный допустимый провайдер",
        LOWER_SCORE => "допустим, но уступил по скору",
        PROVIDER_REJECTED => "провайдер отказал — идём к следующему",
        PROVIDER_TIMEOUT => "провайдер не ответил вовремя — идём к следующему",
        FALLBACK_AFTER_FAILURE => "выбран после отказа предыдущего провайдера",
        FALLBACK_SELF_PROVIDER => "внешних провайдеров не осталось — self-provider",
        NO_ELIGIBLE_PROVIDER => "ни один провайдер не может принять заявку"
      }.freeze

      def self.describe(code) = DESCRIPTIONS.fetch(code, code)
    end
  end
end
