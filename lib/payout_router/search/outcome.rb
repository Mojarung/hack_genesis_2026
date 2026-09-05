# frozen_string_literal: true

module PayoutRouter
  module Search
    # Итог перебора: сколько конфигураций проверено, что вышло у базовой политики,
    # граница Парето по двум главным целям и лидеры по каждой отдельной метрике.
    class Outcome < Data.define(:evaluations, :elapsed_sec, :base, :front, :bests, :structural, :dominating_base)
      def merge(other)
        Outcome.new(evaluations: evaluations + other.evaluations,
                    elapsed_sec: [elapsed_sec, other.elapsed_sec].max,
                    base: base || other.base,
                    front: Outcome.pareto(front + other.front),
                    bests: Outcome.merge_bests(bests, other.bests),
                    structural: structural.merge(other.structural),
                    dominating_base: dominating_base + other.dominating_base)
      end

      def serialize
        {
          "evaluations" => evaluations, "elapsed_sec" => elapsed_sec.round(1),
          "dominating_base" => dominating_base,
          "base" => base&.serialize,
          "front" => front.map(&:serialize),
          "bests" => bests.transform_values(&:serialize),
          "structural" => structural.transform_values(&:serialize)
        }
      end

      # Недоминируемые точки: ни один другой кандидат не лучше сразу по обеим целям.
      def self.pareto(candidates)
        sorted = candidates.sort_by { |candidate| candidate.metrics.frontier_point }
        front = []
        sorted.each do |candidate|
          next if front.any? { |kept| kept.metrics.dominates?(candidate.metrics) }

          front.reject! { |kept| candidate.metrics.dominates?(kept.metrics) }
          front << candidate
        end
        front
      end

      def self.merge_bests(left, right)
        (left.keys | right.keys).to_h do |key|
          candidates = [left[key], right[key]].compact
          [key, candidates.min_by { |candidate| Outcome.objective(key).call(candidate.metrics) }]
        end
      end

      # Каждая метрика приведена к «меньше — лучше», чтобы лидеры выбирались одинаково.
      OBJECTIVES = {
        "min_deviation" => :deviation_pp.to_proc,
        "max_conversion" => ->(metrics) { -metrics.conversion },
        "max_margin" => ->(metrics) { -metrics.margin_per_op },
        "min_fallback" => :fallback_rate.to_proc,
        "max_backtest_uplift" => ->(metrics) { -metrics.backtest_uplift_pct },
        "min_scalar" => :scalar.to_proc
      }.freeze

      def self.objective(key) = OBJECTIVES.fetch(key)
    end
  end
end
