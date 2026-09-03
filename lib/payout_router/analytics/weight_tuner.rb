# frozen_string_literal: true

module PayoutRouter
  module Analytics
    # Подбор весов целей под бизнес-цель: минимизируем отклонение от целевых долей, штрафуем
    # fallback и низкую ожидаемую конверсию. Случайный поиск по симплексу весов + покоординатная
    # доводка. Никакого обучения — каждая кандидатура прогоняется через настоящий роутер.
    class WeightTuner
      Objective = Data.define(:deviation_pp, :fallback_rate, :expected_conversion, :value) do
        def serialize
          { "deviation_pp_total" => deviation_pp.round(1), "fallback_rate" => fallback_rate.round(3),
            "expected_conversion" => expected_conversion.round(3), "objective" => value.round(4) }
        end
      end

      Result = Data.define(:policy, :before, :after, :evaluations) do
        def serialize
          { "goals" => policy.goals, "before" => before.serialize, "after" => after.serialize,
            "evaluations" => evaluations }
        end
      end

      WEIGHTS = { deviation: 1.0, fallback: 1.0, conversion: 1.0 }.freeze
      STEP = 0.05

      def initialize(comparison:, policy:, candidates: 150, seed: 1, weights: WEIGHTS)
        @comparison = comparison
        @policy = policy
        @candidates = candidates
        @rng = Random.new(seed)
        @weights = weights
        @evaluations = 0
      end

      def call
        if @policy.selection.chain?
          raise PolicyError,
                "tune подбирает веса для selection.mode: weighted; у политики #{@policy.name} режим chain"
        end

        before = objective(@policy)
        best_policy = @policy
        best = before
        @candidates.times do
          candidate = @policy.with_goals(random_goals)
          score = objective(candidate)
          if score.value < best.value
            best_policy = candidate
            best = score
          end
        end
        best_policy, best = refine(best_policy, best)
        Result.new(policy: best_policy.with(name: "#{@policy.name}_tuned"), before: before, after: best,
                   evaluations: @evaluations)
      end

      private

      def tunable = @policy.goals.keys

      # Случайная точка на симплексе: веса ≥ 0, сумма 1, округление до 0.01 для читаемости.
      def random_goals
        raw = tunable.map { -Math.log(1 - @rng.rand) }
        total = raw.sum
        tunable.zip(raw).to_h { |goal, weight| [goal, (weight / total).round(2)] }
      end

      # Покоординатная доводка: пробуем ±STEP по каждой цели, пока есть улучшение (не более 3 проходов).
      def refine(policy, best)
        3.times do
          improved = false
          tunable.each do |goal|
            [STEP, -STEP].each do |delta|
              candidate = shifted(policy, goal, delta)
              next if candidate.nil?

              score = objective(candidate)
              next unless score.value < best.value

              policy = candidate
              best = score
              improved = true
            end
          end
          break unless improved
        end
        [policy, best]
      end

      def shifted(policy, goal, delta)
        weight = policy.goals[goal] + delta
        return nil if weight.negative?

        policy.with_goals(goal => weight.round(2))
      end

      def objective(policy)
        if policy.enabled_goals.empty?
          return Objective.new(deviation_pp: Float::INFINITY, fallback_rate: 1.0, expected_conversion: 0.0,
                               value: Float::INFINITY)
        end

        @evaluations += 1
        row = @comparison.evaluate(policy)
        fallback_rate = if row.distribution.empty?
                          0.0
                        else
                          row.fallback.to_f / [row.distribution.values.sum do |s|
                            s["count"]
                          end, 1].max
                        end
        value = (@weights[:deviation] * row.deviation_pp / 100.0) + (@weights[:fallback] * fallback_rate) +
                (@weights[:conversion] * (1.0 - row.expected_conversion))
        Objective.new(deviation_pp: row.deviation_pp, fallback_rate: fallback_rate,
                      expected_conversion: row.expected_conversion, value: value)
      end
    end
  end
end
