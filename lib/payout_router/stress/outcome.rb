# frozen_string_literal: true

module PayoutRouter
  module Stress
    # Результат одного сценария: что случилось на самом деле плюс список нарушений инвариантов.
    # Метрики не сравниваются с порогами — они печатаются. Смысл стресс-прогона в том,
    # чтобы увидеть картину, а не в том, чтобы получить галочку.
    class Outcome < Data.define(:scenario, :stats, :ledger, :violations, :elapsed_sec)
      SHARE_FIELDS = %w[count share_pct target_pct deviation_pp
                        proportional_target_pct proportional_deviation_pp].freeze

      def key = scenario.key
      def title = scenario.title
      def ok? = violations.empty?
      def total = stats.total
      def unrouted = stats.unrouted
      def retries = stats.retries
      def fallback_pct = pct(stats.fallback_count, total)
      def approved_pct = pct(stats.results["approved"], total)
      def ops_per_sec = elapsed_sec.zero? ? 0.0 : (total / elapsed_sec).round

      # Сколько раз предохранитель уводил провайдеров в карантин: без этого числа
      # сценарий «шторм отказов» ничего не доказывал бы.
      def circuit_trips = external_states.sum(&:circuit_trips)

      # Доля заявок, где после hard-правил осталось больше одного кандидата, то есть где скоринг
      # вообще что-то решал. Число маленькое — значит распределение определили hard-правила,
      # и отклонение от целей в этом сценарии ничего не говорит о стратегии. Без этой колонки
      # легко принять арифметику лимитов и банковских фильтров за работу целей.
      def contested_pct = pct(stats.goal_activity["contested_operations"], total)

      # Σ|отклонение| по внешним провайдерам: от целевой доли из снимка и от достижимой.
      def deviation_pp = sum_abs("deviation_pp")
      def proportional_deviation_pp = sum_abs("proportional_deviation_pp")

      # Самый загруженный внешний провайдер по дневному лимиту — видно, упёрлись мы в потолок или нет.
      def max_utilization_pct
        values = stats.utilization.filter_map { |name, row| row["utilization_pct"] if external?(name) }
        values.max || 0.0
      end

      # На сколько заявок self-provider принял больше, чем у него реквизитов. Ёмкость его не
      # ограничивает по замыслу (иначе заявка осталась бы без маршрута), но знать глубину
      # перегрузки надо: это цена того, что мы никого не теряем.
      def fallback_overload
        state = ledger.fallback_state
        return 0 if state.nil? || state.min_available_requisites >= 0

        -state.min_available_requisites
      end

      # Насколько близко к лимиту одновременных заявок подходил пик.
      def peak_in_progress_pct
        values = external_states.filter_map do |state|
          limit = state.provider.in_progress_count_limit
          state.peak_in_progress_count * 100.0 / limit if limit&.positive?
        end
        values.max&.round(1) || 0.0
      end

      def serialize
        {
          "scenario" => key.to_s, "title" => title, "note" => scenario.note,
          "operations" => total, "unrouted" => unrouted, "fallback_pct" => fallback_pct,
          "retries" => retries, "approved_pct" => approved_pct,
          "deviation_pp" => deviation_pp, "proportional_deviation_pp" => proportional_deviation_pp,
          "max_daily_utilization_pct" => max_utilization_pct, "peak_in_progress_pct" => peak_in_progress_pct,
          "fallback_overload" => fallback_overload, "circuit_trips" => circuit_trips,
          "contested_pct" => contested_pct,
          "ops_per_sec" => ops_per_sec, "elapsed_sec" => elapsed_sec.round(3),
          "invariant_violations" => violations.map(&:to_s),
          "distribution" => stats.distribution.transform_values { |share| share.slice(*SHARE_FIELDS) },
          "skip_reasons" => stats.skip_reasons
        }
      end

      private

      def external_states = ledger.states.values.select { |state| state.provider.external? }
      def external?(name) = ledger.states[name]&.provider&.external?

      def sum_abs(field)
        stats.distribution.sum { |name, share| external?(name) ? share[field].abs : 0 }.round(1)
      end

      def pct(part, whole) = whole.zero? ? 0.0 : (part * 100.0 / whole).round(1)
    end
  end
end
