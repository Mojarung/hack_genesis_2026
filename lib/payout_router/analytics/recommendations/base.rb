# frozen_string_literal: true

module PayoutRouter
  module Analytics
    module Recommendations
      # Правило рекомендаций: смотрит на контекст и предлагает конкретные изменения параметров.
      # Новое правило = класс-наследник + строка в Engine::RULES.
      class Base
        def self.key = @key ||= name.split("::").last.gsub(/([a-z\d])([A-Z])/, "\\1_\\2").downcase

        def call(_context) = raise(NotImplementedError, "#{self.class}#call")

        private

        def recommend(**attrs) = Recommendation.new(rule: self.class.key, **attrs)

        # 3 200 000 ₽ — так читается быстрее, чем 3200000.
        def money(value)
          return "—" if value.nil?

          "#{value.round.to_s.reverse.scan(/\d{1,3}/).join(" ").reverse} ₽"
        end

        def round_to(value, step) = (value / step.to_f).round * step
        def ceil_to(value, step) = (value / step.to_f).ceil * step
      end
    end
  end
end
