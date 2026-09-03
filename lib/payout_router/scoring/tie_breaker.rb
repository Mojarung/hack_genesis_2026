# frozen_string_literal: true

module PayoutRouter
  module Scoring
    # При равном скоре порядок задаёт политика: tie_breakers: [priority, conversion, name].
    class TieBreaker
      RULES = {
        "priority" => ->(subject) { subject.provider.priority },
        "conversion" => ->(subject) { -subject.provider.conversion_24h.to_f },
        "latency" => ->(subject) { subject.provider.avg_latency_sec || Float::INFINITY },
        "name" => lambda(&:name)
      }.freeze
      PRECISION = 9

      def self.validate!(key, source: "policy")
        return if RULES.key?(key)

        raise PolicyError, "#{source}: неизвестный tie_breaker «#{key}» (доступны: #{RULES.keys.join(", ")})"
      end

      def initialize(keys)
        keys.each { |key| self.class.validate!(key) }
        @rules = (keys + ["name"]).uniq.map { |key| RULES.fetch(key) }
      end

      # Ключ сортировки: сначала скор по убыванию, затем tie-breakers по порядку.
      def sort_key(score) = [-score.total.round(PRECISION), *tie_key(score)]

      # Только tie-breakers — для чего угодно с provider и name (Score, Candidate).
      def tie_key(subject) = @rules.map { |rule| rule.call(subject) }
    end
  end
end
