# frozen_string_literal: true

module PayoutRouter
  module Analytics
    module Recommendations
      # Провайдер существенно недобирает целевую долю. Причина либо в hard-правилах
      # (цель недостижима — предлагаем расширить фильтр или снизить цель), либо в скоринге.
      class ShareShortfall < Base
        THRESHOLD_PP = -10

        def call(context)
          context.external.filter_map do |provider|
            share = context.distribution[provider.name]
            next if share["deviation_pp"] > THRESHOLD_PP

            attainability = context.attainability[provider.name]
            if attainability["eligible_pct"] < share["target_pct"]
              unattainable(provider, share, attainability)
            else
              outscored(provider, share, context.policy)
            end
          end
        end

        private

        def unattainable(provider, share, attainability)
          reason, count = attainability["blocked_by"].first
          fix = fix_for(provider, reason, attainability)
          recommend(
            provider: provider.name, severity: "warning", parameter: fix[:parameter],
            current: fix[:current], suggested: fix[:suggested],
            message: "#{provider.name}: доля #{share["share_pct"]}% при цели #{share["target_pct"]}% — цель " \
                     "недостижима, провайдер допустим лишь в #{attainability["eligible_pct"]}% заявок " \
                     "(главная причина: #{reason}, #{count} раз). #{fix[:text]}; либо снизить traffic_percentage " \
                     "до достижимых #{round_to(attainability["eligible_pct"], 5)}"
          )
        end

        def outscored(provider, share, policy)
          weight = policy.goals.fetch("traffic_share", 0.0)
          recommend(
            provider: provider.name, severity: "info", parameter: "goals.traffic_share",
            current: weight, suggested: (weight + 0.1).round(2),
            message: "#{provider.name}: доля #{share["share_pct"]}% при цели #{share["target_pct"]}%, хотя провайдер " \
                     "допустим — проигрывает по скору. Поднять вес traffic_share с #{weight} " \
                     "до #{(weight + 0.1).round(2)}"
          )
        end

        def fix_for(provider, reason, attainability)
          case reason
          when Routing::Reasons::BANK_NOT_IN_LIST
            banks = attainability["blocked_banks"].keys.first(3)
            { parameter: "banks", current: provider.banks, suggested: provider.banks + banks,
              text: "Добавить в banks: #{banks.join(", ")}" }
          when Routing::Reasons::AMOUNT_EXCEEDS_LIMIT
            max = ceil_to(attainability["blocked_amounts"]["max"], 10_000)
            { parameter: "limit_amount_max", current: provider.limit_amount_max, suggested: max,
              text: "Поднять limit_amount_max с #{provider.limit_amount_max} до #{max}" }
          when Routing::Reasons::AMOUNT_BELOW_MINIMUM
            min = attainability["blocked_amounts"]["min"]
            { parameter: "limit_amount_min", current: provider.limit_amount_min, suggested: min,
              text: "Опустить limit_amount_min с #{provider.limit_amount_min} до #{min}" }
          else
            { parameter: "traffic_percentage", current: provider.traffic_percentage,
              suggested: round_to(attainability["eligible_pct"], 5), text: "Устранить причину #{reason}" }
          end
        end
      end
    end
  end
end
