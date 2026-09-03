# frozen_string_literal: true

module PayoutRouter
  module Analytics
    module Recommendations
      # Прогоняет все правила и отдаёт рекомендации по убыванию важности.
      class Engine
        RULES = [
          DailyLimitPressure, ShareShortfall, ShareOverflow, FallbackUsage, AmountCoverageGap,
          LowConversionOverload, ConversionDrift, TurnoverMinUnmet, RateLimitHits,
          InProgressPressure, ExpiredHeavy, CircuitTrips
        ].freeze

        def initialize(rules = RULES.map(&:new))
          @rules = rules
        end

        def call(context)
          @rules.flat_map { |rule| rule.call(context) }
                .compact
                .sort_by.with_index { |recommendation, index| [recommendation.rank, index] }
        end
      end
    end
  end
end
