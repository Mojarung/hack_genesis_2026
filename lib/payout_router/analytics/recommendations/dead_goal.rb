# frozen_string_literal: true

module PayoutRouter
  module Analytics
    module Recommendations
      # Цель с ненулевым весом ни разу не различила кандидатов в конкурентных заявках —
      # на этих данных она только размывает веса остальных целей.
      class DeadGoal < Base
        MIN_CONTESTED = 3

        def call(context)
          activity = context.stats.goal_activity
          contested = activity["contested_operations"]
          return [] if contested < MIN_CONTESTED

          activity["goals"].filter_map do |goal, stats|
            next if stats["discriminating_operations"].positive? || stats["weight"].to_f.zero?

            recommend(
              severity: "info", parameter: "goals.#{goal}", current: stats["weight"], suggested: 0,
              message: "цель #{goal} (вес #{stats["weight"]}) не различила кандидатов ни в одной из #{contested} " \
                       "конкурентных заявок — на этой очереди не работает и лишь размывает остальные веса. " \
                       "Снять вес (goals.#{goal}: 0) или изменить её параметры"
            )
          end
        end
      end
    end
  end
end
