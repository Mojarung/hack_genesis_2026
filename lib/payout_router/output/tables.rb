# frozen_string_literal: true

module PayoutRouter
  module Output
    # Строки таблиц для терминала (первая строка — заголовок). CLI только печатает их.
    module Tables
      module_function

      def history(stats)
        rows = stats.providers.map do |name|
          provider = stats.serialize["providers"][name]
          [name, provider["operations"], "#{provider["count_share_pct"]}%", "#{provider["volume_share_pct"]}%",
           provider["conversion"], "#{provider["rejected_pct"]}%", "#{provider["expired_pct"]}%",
           provider["avg_latency_sec"]]
        end
        [%w[провайдер операций доля доля_объёма конверсия отказы таймауты задержка], *rows]
      end

      def backtest(result)
        rows = result.by_provider.map do |name, values|
          [name, values["actual"], values["ours"], values["expected_actual"], values["expected_ours"]]
        end
        [%w[провайдер факт_заявок наш_роутинг ожид_одобр_факт ожид_одобр_наш], *rows]
      end

      def comparison(rows)
        header = %w[политика распределение Σ|откл| fallback ожид_одобр ожид_конв ожид_маржа_₽ задержка]
        [header, *rows.map { |row| comparison_row(row) }]
      end

      def comparison_row(row)
        distribution = row.distribution.map do |name, share|
          "#{name} #{share["count"]} (#{share["share_pct"]}/#{share["target_pct"]}%)"
        end
        [row.policy.name, distribution.join(", "), row.deviation_pp.round(1), row.fallback,
         row.expected_approvals.round(2), row.expected_conversion.round(3), row.expected_margin.round,
         row.avg_latency_sec.round(1)]
      end

      def simulation(summary)
        rows = { "одобрено" => summary.approved, "fallback" => summary.fallback, "повторов" => summary.retries }
        rows.merge!(summary.shares.to_h { |name, values| ["доля #{name} %", values] })
        [%w[показатель mean p5 p50 p95 max],
         *rows.map { |label, v| [label, v["mean"], v["p5"], v["p50"], v["p95"], v["max"]] }]
      end

      def tuned_goals(policy, result)
        [%w[цель было стало], *policy.goals.map { |goal, weight| [goal, weight, result.policy.goals[goal]] }]
      end

      def tuned_objective(result)
        before = result.before.serialize
        after = result.after.serialize
        [%w[показатель до после], *before.keys.map { |key| [key, before[key], after[key]] }]
      end
    end
  end
end
