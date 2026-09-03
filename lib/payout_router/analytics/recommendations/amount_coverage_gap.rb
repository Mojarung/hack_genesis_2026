# frozen_string_literal: true

module PayoutRouter
  module Analytics
    module Recommendations
      # Есть суммы, которые ни один внешний провайдер не принимает по диапазону чека.
      class AmountCoverageGap < Base
        AMOUNT_REASONS = [Routing::Reasons::AMOUNT_EXCEEDS_LIMIT, Routing::Reasons::AMOUNT_BELOW_MINIMUM].freeze

        def call(context)
          gaps = context.stats.decisions.filter_map { |decision| amount_gap(decision, context) }
          return [] if gaps.empty?

          [above(gaps.select { |reason, _| reason == Routing::Reasons::AMOUNT_EXCEEDS_LIMIT }, context),
           below(gaps.select { |reason, _| reason == Routing::Reasons::AMOUNT_BELOW_MINIMUM }, context)].compact
        end

        private

        # Заявка не ушла ни одному внешнему провайдеру, и у каждого из них причина — диапазон суммы.
        def amount_gap(decision, context)
          return nil unless decision.fallback_used || !decision.routed?

          external = decision.attempts.select { |attempt| context.provider(attempt.provider)&.external? }
          return nil if external.empty? || external.any? { |attempt| !AMOUNT_REASONS.include?(attempt.reason) }

          [external.first.reason, decision.operation.amount]
        end

        def above(gaps, context)
          return nil if gaps.empty?

          amounts = gaps.map(&:last)
          provider = context.external.max_by { |candidate| candidate.limit_amount_max || Float::INFINITY }
          suggested = ceil_to(amounts.max, 50_000)
          recommend(
            provider: provider.name, severity: "warning", parameter: "limit_amount_max",
            current: provider.limit_amount_max, suggested: suggested,
            message: "#{gaps.size} заявок на суммы #{money(amounts.min)}–#{money(amounts.max)} " \
                     "не принял ни один внешний " \
                     "провайдер (limit_amount_max) — поднять limit_amount_max у #{provider.name} с " \
                     "#{provider.limit_amount_max} до #{suggested}"
          )
        end

        def below(gaps, context)
          return nil if gaps.empty?

          amounts = gaps.map(&:last)
          provider = context.external.min_by { |candidate| candidate.limit_amount_min || 0 }
          recommend(
            provider: provider.name, severity: "warning", parameter: "limit_amount_min",
            current: provider.limit_amount_min, suggested: amounts.min,
            message: "#{gaps.size} заявок на суммы #{money(amounts.min)}–#{money(amounts.max)} " \
                     "ниже минимального чека " \
                     "всех внешних провайдеров — опустить limit_amount_min у #{provider.name} с " \
                     "#{provider.limit_amount_min} до #{amounts.min}"
          )
        end
      end
    end
  end
end
