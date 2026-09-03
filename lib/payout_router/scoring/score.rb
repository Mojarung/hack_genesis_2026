# frozen_string_literal: true

module PayoutRouter
  module Scoring
    # Итоговый скор кандидата с разложением по целям (или шагам цепочки) — основа объяснения «почему выбран».
    class Score < Data.define(:candidate, :total, :components)
      def provider = candidate.provider
      def name = candidate.name

      def breakdown = components.to_h { |component| [component.goal, component.serialize] }

      # Решающие цели. С соперником (versus) — те, что дали наибольший перевес над ним:
      # цель с большим вкладом, но одинаковым у обоих, ничего не решала. Без соперника — наибольшие вклады.
      def summary(versus: nil)
        edges = versus ? edges_over(versus) : components.map { |component| [component.goal, component.weighted] }
        top = edges.select { |_goal, edge| edge.positive? }.sort_by { |_goal, edge| -edge }.first(2)
        return "score #{total.round(4)}" if top.empty?

        label = versus ? "decisive vs #{versus.name}" : "decisive"
        "score #{total.round(4)}; #{label}: #{top.map { |goal, edge| "#{goal} (+#{edge.round(3)})" }.join(", ")}"
      end

      private

      def edges_over(other)
        theirs = other.components.to_h { |component| [component.goal, component.weighted] }
        components.map { |component| [component.goal, component.weighted - theirs.fetch(component.goal, 0.0)] }
      end
    end
  end
end
