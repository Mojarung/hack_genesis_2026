# frozen_string_literal: true

module PayoutRouter
  module Output
    # Сводка прогона для терминала: распределение, исходы, причины отсева, рекомендации.
    class Summary
      def initialize(run)
        @run = run
        @report = run.report
      end

      def headline
        simulation = @report["simulation"]
        "Заявок: #{@report["total_operations"]} · маршрутизировано: #{@report["routed_operations"]} · " \
          "fallback: #{@report["fallback_operations"]} · без маршрута: #{@report["unrouted_operations"]} · " \
          "политика: #{@run.policy.name} · симуляция: #{simulation["mode"]}" \
          "#{" (seed #{simulation["seed"]})" if simulation["mode"] == "conversion"}"
      end

      # Таблица распределения (первая строка — заголовок) для Thor#print_table.
      def distribution_rows
        header = %w[провайдер заявок доля цель откл. дост.цель откл.дост объём доля_объёма загрузка_дня]
        rows = @report["distribution"].map do |name, share|
          usage = @report["projected_daily_utilization"][name]
          [name, share["count"], pct(share["share_pct"]), pct(share["target_pct"]), signed(share["deviation_pp"]),
           pct(share["proportional_target_pct"]), signed(share["proportional_deviation_pp"]),
           share["volume"], pct(share["volume_share_pct"]),
           usage["utilization_pct"] ? pct(usage["utilization_pct"]) : "—"]
        end
        [header, *rows]
      end

      def result_lines
        results = @report["results"]
        lines = ["Исходы: approved #{results["approved"]}, rejected #{results["rejected"]}, " \
                 "expired #{results["expired"]}; " \
                 "попыток на заявку: #{@report["attempts"]["avg_per_operation"]}, " \
                 "повторов после отказа: #{@report["attempts"]["retries_after_failure"]}"]
        reasons = @report["skip_reasons"].map { |reason, count| "#{reason} ×#{count}" }
        lines << "Причины отсева: #{reasons.empty? ? "нет" : reasons.join(", ")}"
        lines
      end

      def recommendation_lines
        details = @report["recommendation_details"]
        return ["Рекомендации: нет — распределение в норме"] if details.empty?

        ["Рекомендации:"] + details.map.with_index(1) do |rec, index|
          "  #{index}. [#{rec["severity"]}] #{rec["message"]}"
        end
      end

      private

      def pct(value) = "#{value}%"
      def signed(value) = format("%+.1f", value)
    end
  end
end
