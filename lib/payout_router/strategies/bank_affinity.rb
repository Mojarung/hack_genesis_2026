# frozen_string_literal: true

module PayoutRouter
  module Strategies
    # Сродство к банку: по истории один и тот же банк у разных провайдеров одобряется по-разному.
    # Оценка — конверсия пары провайдер × банк из Analytics::ApprovalModel (усаженная к конверсии
    # провайдера, не меньше MIN_BANK_SAMPLES наблюдений); если наблюдений мало — конверсия провайдера
    # в целом; без истории цель нейтральна.
    class BankAffinity < Base
      def evaluate(candidate, context)
        return signal(NEUTRAL, "no history") if approval_model.nil?

        bank = context.operation.bank
        estimate = approval_model.estimate(candidate.name, bank)
        case estimate.source
        when "bank_history"
          signal(estimate.probability,
                 "#{bank} via #{candidate.name}: #{estimate.samples} in history, " \
                 "approval #{pct(estimate.probability * 100)}")
        when "provider_history"
          seen = bank ? @history.bank_counts(candidate.name, bank).first : 0
          signal(estimate.probability,
                 "#{bank || "bank"} via #{candidate.name}: #{seen} in history " \
                 "(< #{Analytics::ApprovalModel::MIN_BANK_SAMPLES}), using provider overall: " \
                 "#{estimate.samples} ops, approval #{pct(estimate.probability * 100)}")
        else
          signal(NEUTRAL, "no history for #{candidate.name}")
        end
      end
    end
  end
end
