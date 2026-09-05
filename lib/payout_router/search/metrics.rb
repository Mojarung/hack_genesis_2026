# frozen_string_literal: true

module PayoutRouter
  module Search
    # Метрики одной конфигурации политики на батарее очередей: доли и одобрения усреднены
    # по очередям, бэктест один — на истории организаторов. Все поля измерены настоящим
    # роутером, никакой аппроксимации: перебор отличается от обычного прогона только числом прогонов.
    class Metrics < Data.define(:deviation_pp, :worst_deviation_pp, :conversion, :margin_per_op,
                                :fallback_rate, :unrouted_rate, :backtest_uplift_pct)
      # Допуск по каждой оси фронта: 0.01 п.п. отклонения и 0.001% конверсии. Без него
      # околонулевые различия делают недоминируемыми тысячи практически одинаковых точек.
      TOLERANCE = [0.01, 1e-5].freeze

      # Две главные цели перебора: отклонение от целевых долей вниз, ожидаемая конверсия вверх.
      # Остальное — атрибуты кандидата, а не оси Парето: по ним отбираем лидеров отдельно.
      def frontier_point = [deviation_pp, -conversion]

      def dominates?(other)
        mine = frontier_point
        theirs = other.frontier_point
        return false unless mine.zip(theirs, TOLERANCE).all? { |a, b, tol| a <= b + tol }

        mine.zip(theirs, TOLERANCE).any? { |a, b, tol| a < b - tol }
      end

      # Скалярная свёртка того же вида, что в подборе весов: одна точка фронта, не «лучшая политика».
      def scalar(deviation: 1.0, fallback: 1.0, conversion: 1.0)
        (deviation * deviation_pp / 100.0) + (fallback * fallback_rate) + (conversion * (1.0 - self.conversion))
      end

      def serialize
        {
          "deviation_pp" => deviation_pp.round(2), "worst_deviation_pp" => worst_deviation_pp.round(2),
          "conversion" => conversion.round(4), "margin_per_op" => margin_per_op.round(2),
          "fallback_rate" => fallback_rate.round(4), "unrouted_rate" => unrouted_rate.round(4),
          "backtest_uplift_pct" => backtest_uplift_pct.round(2)
        }
      end
    end
  end
end
