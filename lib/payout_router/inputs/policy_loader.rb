# frozen_string_literal: true

require "yaml"

module PayoutRouter
  module Inputs
    # config/policy.yml → Domain::Policy. Здесь же ловим опечатки в названиях правил,
    # целей и параметров провайдеров — до начала роутинга, а не посреди него.
    class PolicyLoader
      OVERRIDABLE_FIELDS = (Domain::Provider.members - %i[name fallback]).freeze

      def self.load(path)
        raise InputError, "файл политики не найден: #{path}" unless File.file?(path.to_s)

        new(YAML.safe_load_file(path) || {}, source: path).call
      rescue Psych::SyntaxError => e
        raise PolicyError, "#{path}: невалидный YAML — #{e.message}"
      end

      def self.from_hash(hash, source: "policy") = new(hash, source: source).call

      def initialize(document, source: "policy")
        raise PolicyError, "#{source}: политика должна быть объектом" unless document.is_a?(Hash)

        @doc = document
        @source = source
      end

      def call
        plugin_paths = plugins # сначала подключаем плагины: их стратегии должны быть известны реестру
        @custom_goals = custom_goals
        Domain::Policy.new(
          name: @doc.fetch("name", "custom").to_s,
          description: @doc["description"]&.to_s&.strip,
          fallback_provider: @doc["fallback_provider"]&.to_s,
          hard_constraints: hard_constraints,
          fallback_constraints: fallback_constraints,
          goals: goals,
          selection: selection,
          custom_goals: @custom_goals,
          plugins: plugin_paths,
          tie_breakers: tie_breakers,
          amount_bands: amount_bands,
          provider_overrides: provider_overrides,
          circuit_breaker: circuit_breaker,
          simulation: simulation,
          share_targets: one_of(@doc, "share_targets", Domain::Policy::SHARE_TARGETS, "absolute",
                                where: "share_targets")
        )
      end

      private

      # Плагины — Ruby-файлы со своими стратегиями (наследники Strategies::Base).
      # Путь — относительно файла политики или корня проекта.
      def plugins
        paths = list("plugins").map do |raw|
          path = resolve_plugin(raw.to_s)
          raise PolicyError, "#{@source}: плагин #{raw} не найден" if path.nil?

          require path
          path
        end
        Strategies::Registry.discover!
        paths
      end

      def resolve_plugin(raw)
        candidates = [raw]
        candidates << File.expand_path(raw, File.dirname(@source)) if File.file?(@source.to_s)
        candidates.map { |candidate| File.expand_path(candidate) }.find { |candidate| File.file?(candidate) }
      end

      # Декларативные цели без кода: по полю провайдера, таблица по провайдерам, таблица провайдер × банк.
      def custom_goals
        raw = @doc.fetch("custom_goals", {})
        raise PolicyError, "#{@source}: custom_goals должен быть объектом" unless raw.is_a?(Hash)

        raw.to_h do |name, definition|
          raise PolicyError, "#{@source}: custom_goals.#{name} должен быть объектом" unless definition.is_a?(Hash)

          type = definition.fetch("type", nil).to_s
          Strategies::Custom.validate!(name.to_s, type, definition, source: @source)
          [name.to_s, Domain::Policy::CustomGoal.new(type: type, options: definition.except("type"))]
        end
      end

      def hard_constraints
        keys = list("hard_constraints").map(&:to_s)
        keys.each { |key| Constraints::Registry.fetch(key) }
        keys
      end

      # Не задано — политика сама берёт статические правила из hard_constraints; пустой список — fallback безусловный.
      def fallback_constraints
        return nil unless @doc.key?("fallback_constraints")

        keys = list("fallback_constraints").map(&:to_s)
        keys.each { |key| Constraints::Registry.fetch(key) }
        keys
      end

      def goals
        raw = @doc.fetch("goals", {})
        raise PolicyError, "#{@source}: goals должен быть объектом «цель: вес»" unless raw.is_a?(Hash)

        weights = weights(raw, "goals")
        if weights.values.none?(&:positive?) && !chain_mode?
          raise PolicyError, "#{@source}: ни одна цель не включена (все веса 0)"
        end

        weights
      end

      def weights(raw, where)
        raw.to_h do |key, weight|
          goal_known!(key.to_s, where)
          unless weight.is_a?(Numeric) && weight >= 0
            raise PolicyError, "#{@source}: вес цели #{key} в #{where} должен быть числом ≥ 0"
          end

          [key.to_s, weight.to_f]
        end
      end

      def goal_known!(key, where)
        return if @custom_goals.key?(key) || Strategies::Registry.registered?(key)

        raise PolicyError, "#{@source}: неизвестная цель «#{key}» в #{where} " \
                           "(доступны: #{(Strategies::Registry.keys + @custom_goals.keys).join(", ")})"
      end

      def chain_mode? = @doc.dig("selection", "mode").to_s == "chain"

      def selection
        raw = @doc.fetch("selection", {})
        raise PolicyError, "#{@source}: selection должен быть объектом" unless raw.is_a?(Hash)

        selection = Domain::Policy::Selection
        mode = one_of(raw, "mode", selection::MODES, "weighted", where: "selection.mode")
        chain = Array(raw["chain"]).each_with_index.map { |step, index| chain_step(step, index) }
        if mode == "chain" && chain.empty?
          raise PolicyError,
                "#{@source}: selection.mode: chain требует непустой selection.chain"
        end

        normalization = one_of(raw, "normalization", selection::NORMALIZATIONS, "pool",
                               where: "selection.normalization")
        selection.new(mode: mode, chain: chain, normalization: normalization)
      end

      # Значение из закрытого списка — с адресом поля в тексте ошибки.
      def one_of(raw, key, allowed, default, where:)
        value = raw.fetch(key, default).to_s
        return value if allowed.include?(value)

        raise PolicyError, "#{@source}: #{where} должен быть одним из #{allowed.join("/")}"
      end

      def chain_step(raw, index)
        where = "selection.chain[#{index}]"
        raise PolicyError, "#{@source}: #{where} должен быть объектом" unless raw.is_a?(Hash)

        goals = if raw.key?("goals")
                  weights(raw["goals"].to_h, where)
                else
                  { raw.fetch("strategy") do
                    raise PolicyError, "#{@source}: #{where}: нужен strategy или goals"
                  end.to_s => 1.0 }
                end
        goals.each_key { |key| goal_known!(key, where) }
        tolerance = raw.fetch("tolerance", 0)
        unless tolerance.is_a?(Numeric) && tolerance >= 0
          raise PolicyError,
                "#{@source}: #{where}: tolerance должен быть числом ≥ 0"
        end

        Domain::Policy::ChainStep.new(goals: goals, tolerance: tolerance.to_f)
      end

      def tie_breakers
        keys = list("tie_breakers").map(&:to_s)
        keys.each { |key| Scoring::TieBreaker.validate!(key, source: @source) }
        keys
      end

      def amount_bands
        list("amount_bands").each_with_index.map do |raw, index|
          where = "#{@source} amount_bands[#{index}]"
          raise PolicyError, "#{where}: ожидается объект с min/max/prefer" unless raw.is_a?(Hash)

          Domain::Policy::AmountBand.new(
            min: optional_number(raw, "min", where),
            max: optional_number(raw, "max", where),
            prefer: Array(raw["prefer"]).map(&:to_s)
          )
        end
      end

      def provider_overrides
        raw = @doc.fetch("providers", {})
        raise PolicyError, "#{@source}: providers должен быть объектом" unless raw.is_a?(Hash)

        raw.to_h do |name, fields|
          raise PolicyError, "#{@source}: параметры провайдера #{name} должны быть объектом" unless fields.is_a?(Hash)

          [name.to_s, fields.to_h { |field, value| [override_field(field, name), value] }]
        end
      end

      def override_field(field, provider)
        key = field.to_sym
        return key if OVERRIDABLE_FIELDS.include?(key)

        raise PolicyError, "#{@source}: у провайдера #{provider} неизвестный параметр #{field} " \
                           "(доступны: #{OVERRIDABLE_FIELDS.join(", ")})"
      end

      def circuit_breaker
        raw = @doc.fetch("circuit_breaker", {})
        raise PolicyError, "#{@source}: circuit_breaker должен быть объектом" unless raw.is_a?(Hash)

        failures = raw.fetch("failures", 3)
        cooldown = raw.fetch("cooldown_sec", 300)
        unless failures.is_a?(Integer) && failures >= 0 && cooldown.is_a?(Integer) && cooldown >= 0
          raise PolicyError, "#{@source}: circuit_breaker.failures и cooldown_sec должны быть целыми числами ≥ 0"
        end

        Domain::Policy::CircuitBreakerSettings.new(failures: failures, cooldown_sec: cooldown)
      end

      def simulation
        raw = @doc.fetch("simulation", {})
        raise PolicyError, "#{@source}: simulation должен быть объектом" unless raw.is_a?(Hash)

        seed = raw.fetch("seed", 42)
        raise PolicyError, "#{@source}: simulation.seed должен быть целым числом" unless seed.is_a?(Integer)

        settings = Domain::Policy::SimulationSettings
        settings.new(seed: seed,
                     mode: one_of(raw, "mode", settings::MODES, "optimistic", where: "simulation.mode"),
                     timeout: one_of(raw, "timeout", settings::TIMEOUTS, "cascade", where: "simulation.timeout"))
      end

      def list(key)
        value = @doc.fetch(key, [])
        raise PolicyError, "#{@source}: #{key} должен быть списком" unless value.is_a?(Array)

        value
      end

      def optional_number(hash, key, where)
        value = hash[key]
        return nil if value.nil?
        raise PolicyError, "#{where}: #{key} должен быть числом" unless value.is_a?(Numeric)

        value
      end
    end
  end
end
