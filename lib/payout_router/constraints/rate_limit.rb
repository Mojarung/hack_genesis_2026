# frozen_string_literal: true

module PayoutRouter
  module Constraints
    # Интенсивность: не больше requests_per_minute_limit отправок за скользящую минуту.
    class RateLimit < Base
      def call(candidate, _operation, now)
        limit = candidate.provider.requests_per_minute_limit
        return pass if limit.nil?

        recent = candidate.state.requests_within(now)
        return pass if recent < limit

        violation(Routing::Reasons::RATE_LIMIT_EXCEEDED,
                  "#{recent} requests in last #{State::ProviderState::RATE_WINDOW_SEC}s " \
                  ">= requests_per_minute_limit #{limit}")
      end
    end
  end
end
