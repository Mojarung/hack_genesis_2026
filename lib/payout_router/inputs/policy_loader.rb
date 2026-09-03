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
        Domain::Policy.new(
          name: @doc.fetch("name", "custom").to_s,
          description: @doc["description"]&.to_s&.strip,
          fallback_provider: @doc["fallback_provider"]&.to_s,
          hard_constraints: hard_constraints,
          goals: goals,
          tie_breakers: tie_breakers,
          amount_bands: amount_bands,
          provider_overrides: provider_overrides,
          simulation: simulation
        )
      end

      private

      def hard_constraints
        keys = list("hard_constraints").map(&:to_s)
        keys.each { |key| Constraints::Registry.fetch(key) }
        keys
      end

      def goals
        raw = @doc["goals"]
        raise PolicyError, "#{@source}: goals должен быть объектом «цель: вес»" unless raw.is_a?(Hash)

        weights = raw.to_h do |key, weight|
          Strategies::Registry.fetch(key.to_s)
          unless weight.is_a?(Numeric) && weight >= 0
            raise PolicyError, "#{@source}: вес цели #{key} должен быть числом ≥ 0"
          end

          [key.to_s, weight.to_f]
        end
        raise PolicyError, "#{@source}: ни одна цель не включена (все веса 0)" if weights.values.none?(&:positive?)

        weights
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

      def simulation
        raw = @doc.fetch("simulation", {})
        raise PolicyError, "#{@source}: simulation должен быть объектом" unless raw.is_a?(Hash)

        mode = raw.fetch("mode", "optimistic").to_s
        unless Domain::Policy::SimulationSettings::MODES.include?(mode)
          raise PolicyError, "#{@source}: simulation.mode должен быть одним из " \
                             "#{Domain::Policy::SimulationSettings::MODES.join("/")}"
        end
        seed = raw.fetch("seed", 42)
        raise PolicyError, "#{@source}: simulation.seed должен быть целым числом" unless seed.is_a?(Integer)

        Domain::Policy::SimulationSettings.new(mode: mode, seed: seed)
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
