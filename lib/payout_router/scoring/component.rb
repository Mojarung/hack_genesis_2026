# frozen_string_literal: true

module PayoutRouter
  module Scoring
    # Вклад одной цели в итоговый скор кандидата: score — оценка стратегии как есть,
    # normalized — после приведения к шкале пула (равна score без нормировки), weighted — вклад с весом.
    class Component < Data.define(:goal, :weight, :score, :normalized, :weighted, :note)
      def initialize(goal:, weight:, score:, weighted:, note:, normalized: nil)
        super(goal: goal, weight: weight, score: score, normalized: normalized || score, weighted: weighted, note: note)
      end

      def normalized? = (normalized - score).abs > 1e-9

      def serialize
        hash = { "score" => score.round(4) }
        hash["normalized"] = normalized.round(4) if normalized?
        hash.merge("weight" => weight.round(4), "weighted" => weighted.round(4), "note" => note)
      end
    end
  end
end
