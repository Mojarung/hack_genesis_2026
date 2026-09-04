# frozen_string_literal: true

module PayoutRouter
  module Strategies
    # Soft-goal: отвечает «кого из допустимых предпочесть». Возвращает оценку 0..1,
    # где 1 — «очень хотим отдать заявку сюда». Веса целей задаёт политика.
    # Новая стратегия = новый класс-наследник + ключ в политике (goals).
    class Base
      NEUTRAL = 0.5
      EPSILON = 1e-9

      # Целевая доля кандидата: pct — по которой считаем недобор, original — как записано в снимке.
      Target = Data.define(:pct, :original, :attainable_sum) do
        def renormalized? = !attainable_sum.nil?

        def note = renormalized? ? format(" (was %.1f%%, eligible hold %.1f%%)", original, attainable_sum) : ""
      end

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

      # Целевая доля кандидата; блок отдаёт цель одного кандидата (по количеству или по объёму).
      # share_targets: absolute — процент из снимка как есть. attainable — тот же процент, пересчитанный
      # на допустимых кандидатов заявки: долю провайдера, не прошедшего hard-правила, всё равно получит
      # кто-то другой, поэтому делим её между оставшимися пропорционально их целям. Без пересчёта недобор
      # недоступного копится вечно, а доступные вечно выглядят «перебравшими» и теряют приоритет —
      # это и есть случай «цель невыполнима, потому что нужная доля у недоступного провайдера».
      def target_share(candidate, context, &own)
        target = own.call(candidate)
        sum = @policy.attainable_share_targets? ? context.pool_target_sum(&own) : nil
        return Target.new(pct: target, original: target, attainable_sum: nil) if sum.nil? || sum <= EPSILON

        Target.new(pct: target * 100.0 / sum, original: target, attainable_sum: sum)
      end

      # Модель одобрения по истории (nil без истории) — общая для целей на конверсии.
      def approval_model
        return @approval_model if defined?(@approval_model)

        @approval_model = if @history && !@history.empty?
                            Analytics::ApprovalModel.new(history: @history,
                                                         snapshot: @snapshot)
                          end
      end

      def pct(value) = format("%.1f%%", value)

      def signed(value) = format("%+.1f", value)
    end
  end
end
