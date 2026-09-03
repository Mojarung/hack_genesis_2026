# frozen_string_literal: true

module PayoutRouter
  module Strategies
    # Стратегия 7: фин. обязательство «не менее X ₽ в сутки». Пока минимум не набран —
    # оценка растёт пропорционально недобору; набран или не задан — нейтральные 0.5.
    class TurnoverMin < Base
      NEUTRAL = 0.5

      def evaluate(candidate, _context)
        minimum = candidate.provider.daily_turnover_min
        return signal(NEUTRAL, "no daily_turnover_min") if minimum.nil? || minimum.zero?

        done = candidate.state.volume_in_flight
        gap = minimum - done
        return signal(NEUTRAL, "daily_turnover_min #{minimum} reached (#{done})") unless gap.positive?

        signal(NEUTRAL + (NEUTRAL * gap / minimum), "#{done} of daily_turnover_min #{minimum} (gap #{gap})")
      end
    end
  end
end
