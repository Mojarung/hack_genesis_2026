# frozen_string_literal: true

module PayoutRouter
  module Strategies
    # Soft-goal: отвечает «кого из допустимых предпочесть». Возвращает оценку 0..1,
    # где 1 — «очень хотим отдать заявку сюда». Веса целей задаёт политика.
    # Новая стратегия = новый класс-наследник + ключ в политике (goals).
    class Base
      NEUTRAL = 0.5

      # Ключ цели в политике: TrafficShare → "traffic_share".
      def self.key = @key ||= name.split("::").last.gsub(/([a-z\d])([A-Z])/, "\\1_\\2").downcase

      def key = self.class.key

      # history — Analytics::HistoryStats (может отсутствовать: тогда цели на истории нейтральны).
      def initialize(policy:, snapshot:, history: nil)
        @policy = policy
        @snapshot = snapshot
        @history = history
      end

      # candidate — Routing::Candidate, context — Scoring::Context (operation, ledger, now).
      def evaluate(_candidate, _context) = raise(NotImplementedError, "#{self.class}#evaluate")

      private

      def signal(score, note) = Signal.new(score: score.to_f.clamp(0.0, 1.0), note: note)

      def pct(value) = format("%.1f%%", value)

      def signed(value) = format("%+.1f", value)
    end
  end
end
