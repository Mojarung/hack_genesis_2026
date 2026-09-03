# frozen_string_literal: true

module PayoutRouter
  # Симуляция ответа провайдера. Режимы:
  #   optimistic — каждая отправленная заявка одобрена (детерминированно; режим для итоговой сдачи);
  #   conversion — исход разыгрывается по conversion_24h с фиксированным seed (для демонстрации
  #                каскада «отказ → следующий провайдер» и what-if анализа).
  module Simulation
    def self.build(settings, history_stats: nil)
      case settings.mode
      when "optimistic" then Optimistic.new
      when "conversion" then Conversion.new(seed: settings.seed, history_stats: history_stats)
      else raise PolicyError, "неизвестный режим симуляции «#{settings.mode}»"
      end
    end
  end
end
