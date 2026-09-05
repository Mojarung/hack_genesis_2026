# frozen_string_literal: true

module PayoutRouter
  module Search
    # Одна проверенная конфигурация: откуда взялась, чем отличается структурно, какие веса и что вышло.
    Candidate = Data.define(:origin, :structural, :goals, :metrics) do
      def enabled_goals = goals.reject { |_goal, weight| weight.to_f.zero? }

      def label = "#{structural} · #{origin}"

      def weights_label
        enabled_goals.sort_by { |_goal, weight| -weight }.map { |goal, weight| "#{goal} #{weight}" }.join(", ")
      end

      def serialize
        { "origin" => origin, "structural" => structural, "goals" => enabled_goals }.merge(metrics.serialize)
      end
    end
  end
end
