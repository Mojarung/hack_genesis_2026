# frozen_string_literal: true

module PayoutRouter
  module Constraints
    class InProgressCount < Base
      def call(candidate, _operation, _now)
        limit = candidate.provider.in_progress_count_limit
        return pass if limit.nil?

        count = candidate.state.in_progress_count
        return pass if count + 1 <= limit

        violation(Routing::Reasons::IN_PROGRESS_COUNT_LIMIT,
                  "in_progress_count #{count} + 1 > in_progress_count_limit #{limit}")
      end
    end
  end
end
