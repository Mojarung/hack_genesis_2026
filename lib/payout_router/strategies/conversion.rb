# frozen_string_literal: true

module PayoutRouter
  module Strategies
    # Стратегия 5: приоритет провайдерам с высокой конверсией. Заявленную conversion_24h калибруем
    # по истории (Analytics::ApprovalModel): партнёр, заявивший 0.91 при 9 одобрениях из 19, получает
    # не 0.91, а оценку между заявленным и наблюдаемым. Без истории — заявленная как есть.
    class Conversion < Base
      def evaluate(candidate, _context)
        declared = candidate.provider.conversion_24h.to_f
        estimate = approval_model&.estimate(candidate.name, nil)
        return signal(declared, "conversion_24h #{declared}") if estimate.nil? || estimate.source != "provider_history"

        signal(estimate.probability,
               "conversion_24h #{declared}, history #{estimate.samples} ops → calibrated " \
               "#{format("%.3f", estimate.probability)}")
      end
    end
  end
end
