# frozen_string_literal: true

module PayoutRouter
  module Output
    # Строки таблиц для терминала (первая строка — заголовок). CLI только печатает их.
    module Tables
      module_function

      # Граница Парето перебора: строки от «держим доли» до «максимум одобрений».
      def search_front(outcome)
        rows = outcome.front.map { |candidate| search_row(candidate) }
        [%w[конфигурация происхождение веса откл_пп конверсия маржа_на_заявку бэктест_%], *rows]
      end

      # Лидеры по каждой отдельной метрике плюс базовая политика для сравнения.
      def search_bests(outcome)
        rows = outcome.bests.map { |key, candidate| [key, *search_row(candidate)] }
        rows << ["base", *search_row(outcome.base)] if outcome.base
        [%w[метрика конфигурация происхождение веса откл_пп конверсия маржа_на_заявку бэктест_%], *rows]
      end

      def search_row(candidate)
        metrics = candidate.metrics
        [candidate.structural, candidate.origin, candidate.weights_label,
         metrics.deviation_pp.round(2), metrics.conversion.round(4), metrics.margin_per_op.round(1),
         format("%+.2f", metrics.backtest_uplift_pct)]
      end

      def history(stats)
        rows = stats.providers.map do |name|
          provider = stats.serialize["providers"][name]
          [name, provider["operations"], "#{provider["count_share_pct"]}%", "#{provider["volume_share_pct"]}%",
           provider["conversion"], "#{provider["rejected_pct"]}%", "#{provider["expired_pct"]}%",
           provider["avg_latency_sec"]]
        end
        [%w[провайдер операций доля доля_объёма конверсия отказы таймауты задержка], *rows]
      end

      def history_buckets(stats)
        rows = stats.amount_buckets.map do |label, bucket|
          [label, bucket["operations"], bucket["approved"], bucket["conversion"] || "—"]
        end
        [%w[сумма_чека операций одобрено конверсия], *rows]
      end

      def history_intervals(stats)
        rows = stats.providers.map do |name|
          interval = stats.conversion_interval(name)
          [name, stats.conversion(name)&.round(3), "[#{interval.first}, #{interval.last}]"]
        end
        [%w[провайдер конверсия 95%_интервал_Уилсона], *rows]
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

      # Стресс-прогон: по строке на сценарий. Инварианты — да/нет, всё остальное — измеренные
      # числа без порогов: таблица показывает, что происходит, а не выносит вердикт.
      def stress(outcomes)
        header = ["сценарий", "заявок", "с_выбором%", "без_маршрута", "fallback%", "повторов",
                  "Σ|откл|", "Σ|откл_дост|", "дневной_лимит%", "пик_in_progress%", "перегруз_self",
                  "карантинов", "заявок/с", "инварианты"]
        rows = outcomes.map do |outcome|
          [outcome.key, outcome.total, outcome.contested_pct, outcome.unrouted, outcome.fallback_pct,
           outcome.retries, outcome.deviation_pp, outcome.proportional_deviation_pp,
           outcome.max_utilization_pct, outcome.peak_in_progress_pct, outcome.fallback_overload,
           outcome.circuit_trips, outcome.ops_per_sec,
           outcome.ok? ? "ок" : "нарушено #{outcome.violations.size}"]
        end
        [header, *rows]
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
