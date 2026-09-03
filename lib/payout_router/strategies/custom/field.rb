# frozen_string_literal: true

module PayoutRouter
  module Strategies
    module Custom
      # Оценка по числовому полю провайдера: min–max по внешним провайдерам; direction higher/lower.
      class Field < Base
        DIRECTIONS = %w[higher lower].freeze

        def self.validate!(name, definition, source: "policy")
          field = definition["field"].to_s
          unless Domain::Provider.members.include?(field.to_sym)
            raise PolicyError, "#{source}: custom_goals.#{name}: неизвестное поле провайдера «#{field}»"
          end
          return if DIRECTIONS.include?(definition.fetch("direction", "higher").to_s)

          raise PolicyError, "#{source}: custom_goals.#{name}: direction должен быть higher или lower"
        end

        def initialize(name, options, policy:, snapshot:, history: nil)
          super(policy: policy, snapshot: snapshot, history: history)
          @name = name
          @field = options["field"].to_sym
          @higher = options.fetch("direction", "higher").to_s == "higher"
          values = snapshot.external.map { |provider| provider.public_send(@field).to_f }
          @min = values.min || 0.0
          @max = values.max || 0.0
        end

        def key = @name

        def evaluate(candidate, _context)
          value = candidate.provider.public_send(@field).to_f
          return signal(NEUTRAL, "#{@field} #{value} (all providers equal)") if @max == @min

          normalized = (value - @min) / (@max - @min)
          signal(@higher ? normalized : 1.0 - normalized,
                 "#{@field} #{value} in [#{@min}, #{@max}], #{@higher ? "higher" : "lower"} is better")
        end
      end
    end
  end
end
