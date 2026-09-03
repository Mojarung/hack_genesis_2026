# frozen_string_literal: true

module PayoutRouter
  module Domain
    # Состояние площадки на момент симуляции: провайдеры и метаданные из providers.json.
    class Snapshot < Data.define(:snapshot_at, :gateway, :merchant, :providers)
      def initialize(providers:, snapshot_at: nil, gateway: nil, merchant: nil) = super

      def provider(name) = providers.find { |provider| provider.name == name }
      def names = providers.map(&:name)
      def external = providers.select(&:external?)
      def fallback = providers.find(&:fallback?)
    end
  end
end
