# frozen_string_literal: true

module PayoutRouter
  module Scoring
    # Цепочка стратегий. Шаг 1 делит допустимых кандидатов на ярусы по своей оценке (с допуском
    # tolerance); если верхний ярус — один провайдер, стратегия решила. Иначе ярус передаётся шагу 2,
    # и так далее; после последнего шага — tie-breakers. Стратегия, не применимая к заявке
    # (нет диапазона суммы, нет истории, нет обязательства), даёт всем одинаковую нейтральную оценку
    # и тем самым «уступает» следующей. Ранжирование полное: при отказе провайдера роутер идёт дальше по списку.
    class ChainScorer
      Step = Data.define(:label, :scorer, :tolerance)
      EPSILON = 1e-9

      def initialize(policy:, snapshot:, history: nil)
        if policy.selection.chain.empty?
          raise PolicyError,
                "в политике #{policy.name} режим chain, но цепочка стратегий пуста"
        end

        @steps = policy.selection.chain.each_with_index.map do |step, index|
          scorer = CompositeScorer.new(policy: policy.with(goals: step.goals), snapshot: snapshot, history: history)
          Step.new(label: "#{index + 1}·#{step.label}", scorer: scorer, tolerance: step.tolerance.to_f)
        end
        @tie_breaker = TieBreaker.new(policy.tie_breakers)
      end

      # Кандидаты по убыванию привлекательности; у каждого — оценки всех шагов и шаг, который его определил.
      def rank(candidates, context)
        table = candidates.to_h { |candidate| [candidate, @steps.map { |step| step.scorer.score(candidate, context) }] }
        order(candidates, table, 0).map { |candidate, decided_at| build(candidate, table[candidate], decided_at) }
      end

      private

      # Рекурсивно: ярусы текущего шага, внутри яруса — следующий шаг.
      def order(pool, table, index)
        return pool.map { |candidate| [candidate, :only] } if pool.size == 1 && index.zero?
        return tie_break(pool) if pool.size <= 1 || index >= @steps.size

        tiers(pool, table, index).flat_map do |tier|
          tier.size == 1 ? [[tier.first, index]] : order(tier, table, index + 1)
        end
      end

      def tiers(pool, table, index)
        sorted = pool.sort_by { |candidate| -table[candidate][index].total }
        sorted.slice_when do |left, right|
          table[left][index].total - table[right][index].total > @steps[index].tolerance + EPSILON
        end.to_a
      end

      def tie_break(pool)
        pool.sort_by { |candidate| @tie_breaker.tie_key(candidate) }.map { |candidate| [candidate, :tie_breakers] }
      end

      def build(candidate, step_scores, decided_at)
        components = step_scores.each_with_index.map do |score, index|
          decisive = decided_at == index
          Component.new(goal: @steps[index].label, weight: decisive ? 1.0 : 0.0, score: score.total,
                        weighted: decisive ? score.total : 0.0, note: "#{status(index, decided_at)} · #{notes(score)}")
        end
        total = decided_at.is_a?(Integer) ? step_scores[decided_at].total : (step_scores.first&.total || 0.0)
        Score.new(candidate: candidate, total: total, components: components)
      end

      def status(index, decided_at)
        return "the only eligible candidate, chain not needed" if decided_at == :only
        return "tie through the whole chain, tie-breakers decided" if decided_at == :tie_breakers
        return "decisive step" if decided_at == index

        index < decided_at ? "tie, passed to the next step" : "not consulted"
      end

      def notes(score) = score.components.map { |component| "#{component.goal}: #{component.note}" }.join("; ")
    end
  end
end
