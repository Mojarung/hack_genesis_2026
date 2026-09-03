# frozen_string_literal: true

module PayoutRouter
  module Analytics
    module Recommendations
      # Заявленная conversion_24h расходится с наблюдаемой в истории — скоринг опирается на неверную метрику.
      class ConversionDrift < Base
        THRESHOLD = 0.08

        def call(context)
          return [] if context.history.empty?

          context.external.filter_map do |provider|
            observed = context.history.conversion(provider.name)
            next if observed.nil?

            delta = observed - provider.conversion_24h.to_f
            next if delta.abs < THRESHOLD

            build(provider, observed, delta, context.history.for(provider.name).operations)
          end
        end

        private

        def build(provider, observed, delta, operations)
          overstated = delta.negative?
          recommend(
            provider: provider.name, severity: overstated ? "warning" : "info",
            parameter: "conversion_24h", current: provider.conversion_24h, suggested: observed.round(2),
            message: "#{provider.name}: заявленная conversion_24h #{provider.conversion_24h} " \
                     "против #{observed.round(2)} " \
                     "в истории (#{operations} операций) — метрика #{overstated ? "завышена" : "занижена"}, " \
                     "скоринг по конверсии #{overstated ? "переоценивает" : "недооценивает"} провайдера. " \
                     "Проверить источник conversion_24h или использовать наблюдаемое значение #{observed.round(2)}"
          )
        end
      end
    end
  end
end
