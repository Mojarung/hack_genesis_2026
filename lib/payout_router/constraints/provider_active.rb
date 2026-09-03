# frozen_string_literal: true

module PayoutRouter
  module Constraints
    class ProviderActive < Base
      def call(candidate, _operation, _now)
        provider = candidate.provider
        return pass if provider.active?

        violation(Routing::Reasons::PROVIDER_INACTIVE, "status=#{provider.status}")
      end
    end
  end
end
