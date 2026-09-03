# frozen_string_literal: true

module PayoutRouter
  module Strategies
    module Custom
      # Оценки провайдер × банк заявки: «заявки альфы отправлять в quickpay».
      class BankTable < Base
        def self.validate!(name, definition, source: "policy")
          scores = definition["scores"]
          valid = scores.is_a?(Hash) && scores.values.all? { |row| row.is_a?(Hash) && row.values.all?(Numeric) }
          return if valid

          raise PolicyError, "#{source}: custom_goals.#{name}: scores должен быть объектом «банк: { провайдер: число }»"
        end

        def initialize(name, options, policy:, snapshot:, history: nil)
          super(policy: policy, snapshot: snapshot, history: history)
          @name = name
          @scores = options.fetch("scores", {}).to_h { |bank, row| [bank.to_s.downcase, row.transform_keys(&:to_s)] }
          @default = options.fetch("default", 0.5).to_f
        end

        def key = @name

        def evaluate(candidate, context)
          row = @scores[context.operation.bank.to_s]
          return signal(@default, "no rule for bank #{context.operation.bank || "?"}, default #{@default}") if row.nil?
          unless row.key?(candidate.name)
            return signal(@default,
                          "bank #{context.operation.bank}: no rule for #{candidate.name}, default #{@default}")
          end

          signal(row[candidate.name], "bank #{context.operation.bank} → #{candidate.name}: #{row[candidate.name]}")
        end
      end
    end
  end
end
