# frozen_string_literal: true

module PayoutRouter
  module Analytics
    module Recommendations
      # Конкретное предложение: какой параметр у какого провайдера и на что поменять.
      class Recommendation < Data.define(:provider, :severity, :rule, :parameter, :current, :suggested, :message)
        SEVERITIES = %w[critical warning info].freeze

        def initialize(rule:, message:, provider: nil, parameter: nil, current: nil, suggested: nil, severity: "info")
          super
        end

        def rank = SEVERITIES.index(severity) || SEVERITIES.size

        def serialize
          {
            "severity" => severity, "rule" => rule, "provider" => provider,
            "parameter" => parameter, "current" => current, "suggested" => suggested, "message" => message
          }
        end
      end
    end
  end
end
