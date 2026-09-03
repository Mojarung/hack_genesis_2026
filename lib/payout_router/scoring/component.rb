# frozen_string_literal: true

module PayoutRouter
  module Scoring
    # Вклад одной цели в итоговый скор кандидата.
    class Component < Data.define(:goal, :weight, :score, :weighted, :note)
      def serialize
        { "score" => score.round(4), "weight" => weight.round(4), "weighted" => weighted.round(4), "note" => note }
      end
    end
  end
end
