# frozen_string_literal: true

module PayoutRouter
  module Domain
    # Политика маршрутизации — всё, что можно менять без правки кода:
    # набор и порядок hard-constraints, веса soft-goals, диапазоны сумм,
    # дополнительные параметры провайдеров, fallback, предохранитель и режим симуляции.
    class Policy < Data.define(:name, :description, :fallback_provider, :hard_constraints, :goals,
                               :tie_breakers, :amount_bands, :provider_overrides, :circuit_breaker, :simulation)
      # Стратегия «по сумме чека»: диапазон и провайдеры, которых в нём предпочитаем.
      class AmountBand < Data.define(:min, :max, :prefer)
        def cover?(amount) = (min.nil? || amount >= min) && (max.nil? || amount <= max)
        def label = "#{min || 0}..#{max || "∞"}"
      end

      class SimulationSettings < Data.define(:mode, :seed)
        MODES = %w[optimistic conversion].freeze

        def initialize(mode: "optimistic", seed: 42) = super
      end

      # Предохранитель: после failures отказов/таймаутов подряд провайдер выбывает на cooldown_sec.
      class CircuitBreakerSettings < Data.define(:failures, :cooldown_sec)
        def initialize(failures: 3, cooldown_sec: 300) = super

        def enabled? = failures.positive?
      end

      def initialize(name: "custom", description: nil, fallback_provider: nil, hard_constraints: [], goals: {},
                     tie_breakers: [], amount_bands: [], provider_overrides: {},
                     circuit_breaker: CircuitBreakerSettings.new, simulation: SimulationSettings.new)
        super
      end

      def enabled_goals = goals.reject { |_goal, weight| weight.zero? }

      def band_for(amount) = amount_bands.find { |band| band.cover?(amount) }

      # Применить политику к снимку: дополнительные параметры провайдеров и флаг fallback.
      def apply(snapshot) = snapshot.with(providers: snapshot.providers.map { |provider| apply_to(provider) })

      def apply_to(provider)
        provider.with(**provider_overrides.fetch(provider.name, {}), fallback: provider.name == fallback_provider)
      end

      # Провайдеры, упомянутые в политике, но отсутствующие в снимке — вероятно, опечатка.
      def unknown_providers(snapshot) = provider_overrides.keys - snapshot.names

      # Политика с другими весами целей (для сравнения и подбора весов).
      def with_goals(new_goals) = with(goals: goals.merge(new_goals.transform_keys(&:to_s).transform_values(&:to_f)))

      # Представление для YAML: можно сохранить и загрузить обратно.
      def to_h_document
        {
          "name" => name, "description" => description, "fallback_provider" => fallback_provider,
          "hard_constraints" => hard_constraints, "goals" => goals, "tie_breakers" => tie_breakers,
          "amount_bands" => amount_bands.map { |band| band.to_h.transform_keys(&:to_s) },
          "providers" => provider_overrides.transform_values { |fields| fields.transform_keys(&:to_s) },
          "circuit_breaker" => circuit_breaker.to_h.transform_keys(&:to_s),
          "simulation" => { "mode" => simulation.mode, "seed" => simulation.seed }
        }
      end
    end
  end
end
