# frozen_string_literal: true

module PayoutRouter
  module Analytics
    module Recommendations
      # Провайдера отсекает лимит интенсивности — трафик уходит другим не по бизнес-причинам.
      class RateLimitHits < Base
        def call(context)
          context.external.filter_map do |provider|
            hits = context.stats.skip_reasons_by_provider.fetch(provider.name, {}).fetch(
              Routing::Reasons::RATE_LIMIT_EXCEEDED, 0
            )
            next if hits.zero?

            limit = provider.requests_per_minute_limit
            recommend(
              provider: provider.name, severity: "warning", parameter: "requests_per_minute_limit",
              current: limit, suggested: limit + 5,
              message: "#{provider.name}: #{hits} заявок отсеяны по интенсивности (лимит #{limit}/мин) — поднять " \
                       "requests_per_minute_limit до #{limit + 5} или добавить терминалы"
            )
          end
        end
      end
    end
  end
end
