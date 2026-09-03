# frozen_string_literal: true

module PayoutRouter
  module Analytics
    module Recommendations
      # Лимиты одновременных заявок (count/amount) или реквизиты режут трафик провайдеру.
      class InProgressPressure < Base
        REASONS = [
          Routing::Reasons::IN_PROGRESS_COUNT_LIMIT, Routing::Reasons::IN_PROGRESS_AMOUNT_LIMIT,
          Routing::Reasons::NO_AVAILABLE_REQUISITES
        ].freeze

        def call(context)
          context.external.filter_map do |provider|
            reasons = context.stats.skip_reasons_by_provider.fetch(provider.name, {}).slice(*REASONS)
            next if reasons.empty?

            build(provider, reasons)
          end
        end

        private

        def build(provider, reasons)
          limit = provider.in_progress_count_limit.to_i
          causes = reasons.map { |reason, count| "#{reason} ×#{count}" }.join(", ")
          recommend(
            provider: provider.name, severity: "warning", parameter: "in_progress_count_limit",
            current: provider.in_progress_count_limit, suggested: limit + 5,
            message: "#{provider.name}: #{reasons.values.sum} заявок отсеяны по лимитам обработки (#{causes}) — " \
                     "поднять in_progress_count_limit с #{provider.in_progress_count_limit} до #{limit + 5} " \
                     "или добавить реквизиты (сейчас #{provider.available_requisites})"
          )
        end
      end
    end
  end
end
