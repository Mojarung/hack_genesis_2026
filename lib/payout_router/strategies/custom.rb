# frozen_string_literal: true

module PayoutRouter
  module Strategies
    # Декларативные цели из policy.yml → custom_goals. Новая стратегия без единой строки Ruby:
    #
    #   custom_goals:
    #     more_requisites: { type: field, field: available_requisites, direction: higher }
    #     q3_partner_deal: { type: table, scores: { payflow: 1.0, vipay: 0.6 }, default: 0.2 }
    #     bank_deal:       { type: bank_table, scores: { alfa: { quickpay: 1.0 } }, default: 0.5 }
    #   goals:
    #     q3_partner_deal: 0.2
    module Custom
      TYPES = { "field" => "Field", "table" => "Table", "bank_table" => "BankTable" }.freeze

      def self.build(name, definition, policy:, snapshot:, history: nil)
        klass = const_get(TYPES.fetch(definition.type))
        klass.new(name, definition.options, policy: policy, snapshot: snapshot, history: history)
      end

      def self.validate!(name, type, definition, source: "policy")
        unless TYPES.key?(type)
          raise PolicyError, "#{source}: custom_goals.#{name}: type должен быть одним из #{TYPES.keys.join("/")}"
        end

        const_get(TYPES.fetch(type)).validate!(name, definition, source: source)
      end

      def self.describe
        {
          "field" => "оценка по числовому полю провайдера, нормированная min–max (direction: higher | lower)",
          "table" => "явные оценки по провайдерам: scores: { vipay: 1.0 }, default для остальных",
          "bank_table" => "оценки провайдер × банк заявки: scores: { alfa: { quickpay: 1.0 } }, default"
        }
      end
    end
  end
end
