# frozen_string_literal: true

module PayoutRouter
  module Analytics
    module Recommendations
      # Заявленная conversion_24h расходится с наблюдаемой в истории статистически значимо:
      # значение из снимка лежит вне 95% интервала Уилсона. Шумовые расхождения на малой выборке не трогаем.
      class ConversionDrift < Base
        def call(context)
          return [] if context.history.empty?

          context.external.filter_map do |provider|
            interval = context.history.conversion_interval(provider.name)
            next if interval.nil? || provider.conversion_24h.to_f.between?(interval.first, interval.last)

            build(provider, context.history.conversion(provider.name), interval,
                  context.history.for(provider.name).operations)
          end
        end

        private

        def build(provider, observed, interval, operations)
          overstated = provider.conversion_24h.to_f > interval.last
          recommend(
            provider: provider.name, severity: overstated ? "warning" : "info",
            parameter: "conversion_24h", current: provider.conversion_24h, suggested: observed.round(2),
            message: "#{provider.name}: заявленная conversion_24h #{provider.conversion_24h} лежит вне 95% интервала " \
                     "по истории [#{interval.first}, #{interval.last}] (#{operations} операций, " \
                     "факт #{observed.round(2)}) — метрика #{overstated ? "завышена" : "занижена"}, " \
                     "скоринг по конверсии #{overstated ? "переоценивает" : "недооценивает"} провайдера. " \
                     "Проверить источник conversion_24h или использовать наблюдаемое значение #{observed.round(2)}"
          )
        end
      end
    end
  end
end
