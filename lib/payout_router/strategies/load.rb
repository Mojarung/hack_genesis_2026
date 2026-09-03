# frozen_string_literal: true

module PayoutRouter
  module Strategies
    # Загрузка: чем ближе провайдер к любому из лимитов (дневной оборот, in-progress),
    # тем ниже оценка. Влияет на выбор задолго до того, как лимит станет hard-отказом.
    class Load < Base
      def evaluate(candidate, _context)
        utilization = candidate.state.utilization
        worst = utilization.values.max
        in_progress = "#{pct(utilization[:in_progress_count] * 100)}/#{pct(utilization[:in_progress_amount] * 100)}"
        note = "utilization #{pct(worst * 100)} (daily #{pct(utilization[:daily] * 100)}, in_progress #{in_progress})"
        signal(1.0 - worst, note)
      end
    end
  end
end
