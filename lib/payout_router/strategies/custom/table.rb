# frozen_string_literal: true

module PayoutRouter
  module Strategies
    module Custom
      # Явные оценки по провайдерам (например, договорённость с партнёром на квартал).
      class Table < Base
        def self.validate!(name, definition, source: "policy")
          scores = definition["scores"]
          return if scores.is_a?(Hash) && scores.values.all?(Numeric)

          raise PolicyError, "#{source}: custom_goals.#{name}: scores должен быть объектом «провайдер: число»"
        end

        def initialize(name, options, policy:, snapshot:, history: nil)
          super(policy: policy, snapshot: snapshot, history: history)
          @name = name
          @scores = options.fetch("scores", {}).transform_keys(&:to_s)
          @default = options.fetch("default", 0.0).to_f
        end

        def key = @name

        def evaluate(candidate, _context)
          if @scores.key?(candidate.name)
            return signal(@scores[candidate.name],
                          "table score #{@scores[candidate.name]}")
          end

          signal(@default, "not in table, default #{@default}")
        end
      end
    end
  end
end
