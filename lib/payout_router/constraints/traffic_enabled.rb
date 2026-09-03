# frozen_string_literal: true

module PayoutRouter
  module Constraints
    # traffic_percentage = 0 означает «провайдер выведен из ротации» (так же считает валидатор
    # организаторов). Fallback-провайдер под это правило не попадает — его доля всегда 0.
    class TrafficEnabled < Base
      def call(candidate, _operation, _now)
        provider = candidate.provider
        return pass if provider.fallback? || provider.traffic_percentage.to_f.positive?

        violation(Routing::Reasons::TRAFFIC_DISABLED, "traffic_percentage=#{provider.traffic_percentage}")
      end
    end
  end
end
