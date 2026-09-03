# frozen_string_literal: true

module PayoutRouter
  module Domain
    # Политика маршрутизации — всё, что можно менять без правки кода:
    # набор и порядок hard-constraints (отдельно — для fallback), способ выбора (веса или цепочка стратегий),
    # свои цели (плагины и декларативные), диапазоны сумм, параметры провайдеров, fallback, предохранитель, симуляция.
    class Policy < Data.define(:name, :description, :fallback_provider, :hard_constraints, :fallback_constraints,
                               :goals, :selection, :custom_goals, :plugins, :tie_breakers, :amount_bands,
                               :provider_overrides, :circuit_breaker, :simulation)
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

      # Шаг цепочки стратегий: одна цель или взвешенная группа; tolerance — разница оценок,
      # внутри которой кандидаты считаются равными и решение передаётся следующему шагу.
      class ChainStep < Data.define(:goals, :tolerance)
        def initialize(goals:, tolerance: 0.0) = super

        def label
          goals.size == 1 ? goals.keys.first : "(#{goals.map { |goal, weight| "#{goal} #{weight}" }.join(", ")})"
        end
      end

      # Способ выбора среди допустимых: weighted — все цели сразу с весами; chain — по очереди.
      # normalization — как взвешенный скоринг приводит оценки целей к общей шкале:
      #   pool     — по разбросу среди кандидатов заявки (лучший 1, худший 0): вес = важность цели;
      #   absolute — оценка стратегии как есть (0..1): вес = цена единицы оценки.
      class Selection < Data.define(:mode, :chain, :normalization)
        MODES = %w[weighted chain].freeze
        NORMALIZATIONS = %w[pool absolute].freeze

        def initialize(mode: "weighted", chain: [], normalization: "pool") = super

        def chain? = mode == "chain"
        def pool_normalization? = normalization == "pool"
      end

      # Декларативная цель из YAML: type — field / table / bank_table, options — её параметры.
      class CustomGoal < Data.define(:type, :options)
      end

      def initialize(name: "custom", description: nil, fallback_provider: nil, hard_constraints: [],
                     fallback_constraints: nil, goals: {}, selection: Selection.new, custom_goals: {}, plugins: [],
                     tie_breakers: [], amount_bands: [], provider_overrides: {},
                     circuit_breaker: CircuitBreakerSettings.new, simulation: SimulationSettings.new)
        super
      end

      def enabled_goals = goals.reject { |_goal, weight| weight.zero? }

      # Правила для fallback-провайдера: заданные явно, иначе — только статические правила допуска
      # из hard_constraints (ёмкостные ограничения self-provider не отсеивают, см. Constraints::Registry::STATIC).
      def fallback_rules = fallback_constraints || (hard_constraints & Constraints::Registry::STATIC)

      def band_for(amount) = amount_bands.find { |band| band.cover?(amount) }

      # Применить политику к снимку: дополнительные параметры провайдеров и флаг fallback.
      def apply(snapshot) = snapshot.with(providers: snapshot.providers.map { |provider| apply_to(provider) })

      def apply_to(provider)
        provider.with(**provider_overrides.fetch(provider.name, {}), fallback: provider.name == fallback_provider)
      end

      # Провайдеры, упомянутые в политике (параметры, диапазоны сумм), но отсутствующие в снимке — вероятно, опечатка.
      def unknown_providers(snapshot)
        (provider_overrides.keys + amount_bands.flat_map(&:prefer)).uniq - snapshot.names
      end

      # Политика с другими весами целей (для сравнения и подбора весов).
      def with_goals(new_goals) = with(goals: goals.merge(new_goals.transform_keys(&:to_s).transform_values(&:to_f)))

      # Короткое описание способа выбора для отчётов.
      def selection_label
        unless selection.chain?
          return "weighted (#{selection.normalization}): #{enabled_goals.map do |goal, weight|
            "#{goal} #{weight}"
          end.join(", ")}"
        end

        "chain: #{selection.chain.map(&:label).join(" → ")}"
      end

      # Представление для YAML: можно сохранить и загрузить обратно.
      def to_h_document
        {
          "name" => name, "description" => description, "fallback_provider" => fallback_provider,
          "plugins" => plugins, "hard_constraints" => hard_constraints, "fallback_constraints" => fallback_rules,
          "goals" => goals, "selection" => selection_document, "custom_goals" => custom_goals_document,
          "tie_breakers" => tie_breakers,
          "amount_bands" => amount_bands.map { |band| band.to_h.transform_keys(&:to_s) },
          "providers" => provider_overrides.transform_values { |fields| fields.transform_keys(&:to_s) },
          "circuit_breaker" => circuit_breaker.to_h.transform_keys(&:to_s),
          "simulation" => { "mode" => simulation.mode, "seed" => simulation.seed }
        }
      end

      private

      def selection_document
        { "mode" => selection.mode, "normalization" => selection.normalization,
          "chain" => selection.chain.map { |step| { "goals" => step.goals, "tolerance" => step.tolerance } } }
      end

      def custom_goals_document
        custom_goals.transform_values { |goal| { "type" => goal.type }.merge(goal.options) }
      end
    end
  end
end
