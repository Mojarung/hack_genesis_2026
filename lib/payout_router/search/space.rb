# frozen_string_literal: true

module PayoutRouter
  module Search
    # Пространство перебора: структурные переключатели (полная сетка) × веса целей.
    # Веса перебираются четырьмя способами сразу — одиночные цели, аблации базовой политики,
    # грубая сетка по влиятельным целям и случайные точки симплекса. Первые два дают
    # интерпретируемые крайности, третий — исчерпывающий срез, четвёртый — покрытие остального.
    class Space
      GOALS = %w[traffic_share share_deficit volume_share cascade_priority amount_band conversion
                 bank_affinity load turnover_min rate_headroom latency margin expected_value].freeze
      # Цели исчерпывающей сетки: те, что реально различают кандидатов на этих данных
      # (по goal_activity), плюс ожидаемая маржа как единственная денежная цель.
      # Сетка — 4^N точек на каждый структурный вариант, поэтому по умолчанию берём три цели
      # (64 точки), а полную шестимерную (4096) включают явно: `--grid` у команды search.
      FULL_GRID_GOALS = %w[traffic_share conversion bank_affinity load amount_band expected_value].freeze
      GRID_GOALS = %w[traffic_share conversion bank_affinity].freeze
      GRID_WEIGHTS = [0.0, 0.05, 0.15, 0.30].freeze
      NORMALIZATIONS = %w[pool absolute damped].freeze
      SHARE_TARGETS = %w[absolute attainable].freeze
      DAILY_LIMITS = %w[daily_limit daily_limit_reserved].freeze

      # Структурные варианты: normalization × share_targets × правило дневного лимита.
      def self.structural(policy)
        NORMALIZATIONS.product(SHARE_TARGETS, DAILY_LIMITS).map do |normalization, targets, limit|
          variant = policy.with(selection: policy.selection.with(normalization: normalization),
                                share_targets: targets,
                                hard_constraints: swap_limit(policy.hard_constraints, limit))
          ["#{normalization}/#{targets}/#{limit}", variant]
        end
      end

      def self.swap_limit(constraints, rule)
        constraints.map { |name| DAILY_LIMITS.include?(name) ? rule : name }
      end

      def initialize(policy:, random_samples: 2000, seed: 1, grid_goals: GRID_GOALS)
        @base = GOALS.to_h { |goal| [goal, policy.goals.fetch(goal, 0.0).to_f] }
        @random_samples = random_samples
        @grid_goals = grid_goals
        @rng = Random.new(seed)
      end

      # Каждый элемент — [метка, хеш весов]. Метка нужна, чтобы в отчёте было видно происхождение
      # кандидата: сетка это, аблация или случайная точка.
      def each(&block)
        return enum_for(:each) unless block

        block.call(["base", @base])
        singles(&block)
        ablations(&block)
        grid(&block)
        random(&block)
      end

      private

      def singles
        GOALS.each { |goal| yield ["only:#{goal}", zeros.merge(goal => 1.0)] }
      end

      def ablations
        @base.each_key do |goal|
          next if @base[goal].zero?

          yield ["base-#{goal}", @base.merge(goal => 0.0)]
        end
      end

      def grid
        GRID_WEIGHTS.repeated_permutation(@grid_goals.size) do |weights|
          next if weights.sum.zero?

          yield ["grid", zeros.merge(@grid_goals.zip(weights).to_h)]
        end
      end

      # Точка симплекса через экспоненциальное распределение: равномерно по всем комбинациям весов.
      def random
        @random_samples.times do |index|
          raw = GOALS.map { -Math.log(1 - @rng.rand) }
          total = raw.sum
          weights = GOALS.zip(raw).to_h { |goal, value| [goal, (value / total).round(3)] }
          next if weights.values.sum.zero?

          yield ["random##{index}", weights]
        end
      end

      def zeros = GOALS.to_h { |goal| [goal, 0.0] }
    end
  end
end
