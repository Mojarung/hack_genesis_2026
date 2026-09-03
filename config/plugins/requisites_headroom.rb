# frozen_string_literal: true

# Пример своей стратегии: наследник PayoutRouter::Strategies::Base в отдельном файле.
# Подключается строкой в политике:
#   plugins: [config/plugins/requisites_headroom.rb]
#   goals:   { requisites_headroom: 0.2 }
# Регистрируется автоматически (Strategies::Registry.discover!), ядро править не нужно.
module PayoutRouter
  module Strategies
    # Предпочитать провайдеров с большим числом свободных реквизитов относительно их «полного» набора.
    class RequisitesHeadroom < Base
      def self.description = "плагин: доля свободных реквизитов от исходного числа в снимке"

      def initialize(policy:, snapshot:, history: nil)
        super
        @initial = snapshot.providers.to_h { |provider| [provider.name, [provider.available_requisites.to_i, 1].max] }
      end

      def evaluate(candidate, _context)
        free = candidate.state.available_requisites
        total = @initial.fetch(candidate.name, 1)
        signal(free.to_f / total, "#{free} of #{total} requisites free")
      end
    end
  end
end
