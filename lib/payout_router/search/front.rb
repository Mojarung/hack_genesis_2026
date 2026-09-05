# frozen_string_literal: true

module PayoutRouter
  module Search
    # Граница Парето, которая достраивается по одному кандидату. Полный пересчёт после каждой
    # точки стоит дороже самого прогона роутера, поэтому фронт держим инкрементально,
    # а совпадающие с точностью допуска точки схлопываем — иначе сетка весов забивает его дублями.
    class Front
      def initialize = @points = {}

      def add?(candidate)
        key = key_for(candidate)
        return false if @points.key?(key)
        return false if @points.each_value.any? { |kept| kept.metrics.dominates?(candidate.metrics) }

        @points.delete_if { |_key, kept| candidate.metrics.dominates?(kept.metrics) }
        @points[key] = candidate
        true
      end

      def size = @points.size

      def candidates = @points.values.sort_by { |candidate| candidate.metrics.frontier_point }

      private

      def key_for(candidate)
        candidate.metrics.frontier_point.zip(Metrics::TOLERANCE).map { |value, tol| (value / tol).round }
      end
    end
  end
end
