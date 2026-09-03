# frozen_string_literal: true

module PayoutRouter
  module Analytics
    module Recommendations
      # Провайдер получает заметно больше цели — обычно как «остаточный» приёмник заявок,
      # которые остальные не прошли по hard-правилам.
      class ShareOverflow < Base
        THRESHOLD_PP = 10

        def call(context)
          context.external.filter_map do |provider|
            share = context.distribution[provider.name]
            next if share["deviation_pp"] < THRESHOLD_PP

            others = context.stats.skip_reasons_by_provider.reject { |name, _| name == provider.name }
            causes = others.flat_map do |name, reasons|
              reasons.first(2).map do |reason, count|
                "#{name}: #{reason} ×#{count}"
              end
            end
            recommend(
              provider: provider.name, severity: "info", parameter: "traffic_percentage",
              current: share["target_pct"], suggested: round_to(share["share_pct"], 5),
              message: "#{provider.name}: доля #{share["share_pct"]}% при цели #{share["target_pct"]}% — принимает " \
                       "переток заявок, которые другие провайдеры не прошли (#{causes.join("; ")}). " \
                       "Либо признать это и поднять traffic_percentage до #{round_to(share["share_pct"], 5)}, " \
                       "либо расширить лимиты/банки у остальных"
            )
          end
        end
      end
    end
  end
end
