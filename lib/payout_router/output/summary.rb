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
          usage = @report["provider_capacity"].fetch(name, {})
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

      # Сколько роутинг взял от точного оптимума очереди — главная цифра прогона.
      def optimality_lines
        block = @report["optimality"]
        return [] if block.nil?

        ["Против оптимума: взято #{block["score_vs_optimum_pct"]}% " \
         "(#{block["expected_approvals_ours"]} из #{block["optimum_same_self_provider_budget"]} ожидаемых " \
         "одобрений у точного решения всей очереди), #{optimality_breakdown(block)}"]
      end

      # Отрицательная «цена онлайна» — роутер обошёл квотный оптимум, держа доли мягко.
      def optimality_breakdown(block)
        online = block["approvals_lost_to_online_decisions"]
        if online.negative?
          "из них #{block["approvals_lost_to_share_targets"]} — цена жёстких целевых долей " \
            "(квотный оптимум #{block["optimum_with_target_shares"]}), но роутер, держа доли мягко, " \
            "отыграл #{-online} из них"
        else
          "из них #{block["approvals_lost_to_share_targets"]} потеряно на удержании целевых долей и " \
            "#{online} — на решениях без знания будущего"
        end
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
