# frozen_string_literal: true

module PayoutRouter
  module Scoring
    # Итоговый скор кандидата с разложением по целям (или шагам цепочки) — основа объяснения «почему выбран».
    class Score < Data.define(:candidate, :total, :components)
      def provider = candidate.provider
      def name = candidate.name

      def breakdown = components.to_h { |component| [component.goal, component.serialize] }

      # Цели с наибольшим вкладом — их называем решающими в details.
      def summary
        top = components.select { |component| component.weighted.positive? }
                        .sort_by { |component| -component.weighted }.first(2)
        return "score #{total.round(4)}" if top.empty?

        "score #{total.round(4)}; decisive: #{top.map { |c| "#{c.goal} (+#{c.weighted.round(3)})" }.join(", ")}"
      end
    end
  end
end
