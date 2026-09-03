# frozen_string_literal: true

module PayoutRouter
  module Scoring
    # Взвешенный скоринг: total = Σ(вес_i × оценка_i) / Σ вес_i по включённым целям.
    # Один механизм покрывает все стратегии из ТЗ и любые их комбинации — меняются только веса.
    class CompositeScorer
      Goal = Data.define(:strategy, :weight)

      attr_reader :goals

      def initialize(policy:, snapshot:, history: nil)
        @goals = policy.enabled_goals.map do |key, weight|
          strategy = Strategies.instantiate(key, policy: policy, snapshot: snapshot, history: history)
          Goal.new(strategy: strategy, weight: weight.to_f)
        end.freeze
        raise PolicyError, "в политике #{policy.name} не включена ни одна цель" if @goals.empty?

        @total_weight = @goals.sum(&:weight)
        @tie_breaker = TieBreaker.new(policy.tie_breakers)
      end

      # Кандидаты по убыванию привлекательности.
      def rank(candidates, context)
        candidates.map { |candidate| score(candidate, context) }.sort_by! { |score| @tie_breaker.sort_key(score) }
      end

      def score(candidate, context)
        components = @goals.map do |goal|
          signal = goal.strategy.evaluate(candidate, context)
          Component.new(goal: goal.strategy.key, weight: goal.weight, score: signal.score,
                        weighted: signal.score * goal.weight / @total_weight, note: signal.note)
        end
        Score.new(candidate: candidate, total: components.sum(&:weighted), components: components)
      end
    end
  end
end
