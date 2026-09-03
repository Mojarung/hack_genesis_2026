# frozen_string_literal: true

module PayoutRouter
  module Scoring
    # Взвешенный скоринг: total = Σ(вес_i × оценка_i) / Σ вес_i по включённым целям.
    # Один механизм покрывает все стратегии из ТЗ и любые их комбинации — меняются только веса.
    #
    # Оценки разных целей живут в разных диапазонах (конверсии 0.79–0.91, доли 0–0.9), поэтому
    # в режиме pool каждая цель перед взвешиванием приводится к разбросу среди кандидатов заявки:
    # лучший — 1, худший — 0, остальные пропорционально, при равенстве — 0.5 (цель не различает).
    # Тогда вес означает ровно то, что написано в политике: важность цели. Режим absolute
    # оставляет оценки как есть (вес — цена единицы оценки); цепочка стратегий работает так.
    class CompositeScorer
      Goal = Data.define(:strategy, :weight)

      # Шкала одной цели по пулу кандидатов.
      class Scale < Data.define(:min, :spread)
        EPSILON = 1e-9

        def self.of(values) = new(min: values.min, spread: values.max - values.min)

        def apply(value) = spread <= EPSILON ? Strategies::Base::NEUTRAL : (value - min) / spread
      end

      attr_reader :goals

      def initialize(policy:, snapshot:, history: nil, normalization: nil)
        @goals = policy.enabled_goals.map do |key, weight|
          strategy = Strategies.instantiate(key, policy: policy, snapshot: snapshot, history: history)
          Goal.new(strategy: strategy, weight: weight.to_f)
        end.freeze
        raise PolicyError, "в политике #{policy.name} не включена ни одна цель" if @goals.empty?

        @total_weight = @goals.sum(&:weight)
        @tie_breaker = TieBreaker.new(policy.tie_breakers)
        @pool = (normalization || policy.selection.normalization) == "pool"
      end

      # Кандидаты по убыванию привлекательности.
      def rank(candidates, context)
        score_all(candidates, context).sort_by! { |score| @tie_breaker.sort_key(score) }
      end

      # Оценки всех кандидатов на одну заявку (с нормировкой по пулу, если она включена).
      def score_all(candidates, context)
        signals = candidates.map { |candidate| evaluate(candidate, context) }
        scales = if @pool && candidates.size > 1
                   @goals.each_index.map do |i|
                     Scale.of(signals.map do |row|
                       row[i].score
                     end)
                   end
                 end
        candidates.each_with_index.map { |candidate, index| build(candidate, signals[index], scales) }
      end

      # Оценка одного кандидата без пула — оценки стратегий как есть.
      def score(candidate, context) = build(candidate, evaluate(candidate, context), nil)

      private

      def evaluate(candidate, context) = @goals.map { |goal| goal.strategy.evaluate(candidate, context) }

      def build(candidate, signals, scales)
        components = @goals.each_with_index.map do |goal, index|
          signal = signals[index]
          normalized = scales ? scales[index].apply(signal.score) : signal.score
          Component.new(goal: goal.strategy.key, weight: goal.weight, score: signal.score, normalized: normalized,
                        weighted: normalized * goal.weight / @total_weight, note: signal.note)
        end
        Score.new(candidate: candidate, total: components.sum(&:weighted), components: components)
      end
    end
  end
end
