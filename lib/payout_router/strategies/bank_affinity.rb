# frozen_string_literal: true

module PayoutRouter
  module Strategies
    # Сродство к банку: по истории один и тот же банк у разных провайдеров одобряется по-разному.
    # Оценка — сглаженная конверсия пары провайдер × банк (Лаплас: (approved + 1) / (n + 2)),
    # если наблюдений мало — конверсия провайдера в целом; без истории цель нейтральна.
    class BankAffinity < Base
      def initialize(policy:, snapshot:, history: nil)
        super
        @model = history && !history.empty? ? Analytics::ApprovalModel.new(history: history, snapshot: snapshot) : nil
      end

      def evaluate(candidate, context)
        return signal(NEUTRAL, "no history") if @model.nil?

        bank = context.operation.bank
        estimate = @model.estimate(candidate.name, bank)
        case estimate.source
        when "bank_history"
          signal(estimate.probability,
                 "#{bank} via #{candidate.name}: #{estimate.samples} in history, " \
                 "smoothed approval #{pct(estimate.probability * 100)}")
        when "provider_history"
          signal(estimate.probability,
                 "no #{bank || "bank"} history for #{candidate.name}; overall #{estimate.samples} ops, " \
                 "smoothed approval #{pct(estimate.probability * 100)}")
        else
          signal(NEUTRAL, "no history for #{candidate.name}")
        end
      end
    end
  end
end
