# frozen_string_literal: true

module PayoutRouter
  module Constraints
    # Прогоняет hard-правила в порядке, заданном политикой. Собираем все нарушения,
    # а не первое: в attempts тогда видна полная картина «почему нельзя».
    class Pipeline
      attr_reader :constraints

      def initialize(keys)
        @constraints = keys.map { |key| Registry.fetch(key).new }.freeze
      end

      def evaluate(candidate, operation, now)
        violations = nil
        @constraints.each do |constraint|
          verdict = constraint.call(candidate, operation, now)
          next if verdict.passed?

          (violations ||= []) << verdict
        end
        Evaluation.new(candidate: candidate, violations: violations || Evaluation::NONE)
      end
    end
  end
end
