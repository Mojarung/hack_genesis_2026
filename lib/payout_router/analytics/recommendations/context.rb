# frozen_string_literal: true

module PayoutRouter
  module Analytics
    module Recommendations
      # Всё, на что смотрят правила: статистика прогона, история, снимок провайдеров, политика.
      class Context < Data.define(:stats, :history, :snapshot, :policy)
        def provider(name) = snapshot.provider(name)
        def external = snapshot.external
        def distribution = stats.distribution
        def utilization = stats.utilization
        def attainability = stats.attainability
        def total = stats.total
      end
    end
  end
end
