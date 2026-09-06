# frozen_string_literal: true

require "thor"

module PayoutRouter
  # Командная строка. Логика — в Runner, Analytics и Output, здесь только разбор опций и печать.
  class CLI < Thor
    package_name "payout_router"

    DEFAULT_QUEUE = "data/operations_queue_10.json"
    SKIP_HINT = "если заявка в очереди неожиданного формата, а файл решений нужен всё равно — " \
                "повторите с --on-invalid skip: битые заявки уйдут в предупреждения, остальные отроутятся"

    def self.exit_on_failure? = true

    class_option :providers, type: :string, default: "data/providers.json", desc: "снимок провайдеров (providers.json)"
    class_option :history, type: :string, default: "data/operations_history.csv",
                           desc: "история операций (CSV); пустая строка — без истории"
    class_option :policy, type: :string, default: "config/policy.yml", desc: "политика маршрутизации (YAML)"

    desc "route", "Распределить очередь заявок: routing_decisions.json + routing_report.json (+ HTML-дашборд)"
    option :queue, type: :string, default: DEFAULT_QUEUE, desc: "очередь заявок (JSON)"
    option :out, type: :string, default: "out", desc: "каталог результата"
    option :suffix, type: :string, default: "", desc: "суффикс имён файлов, например _test"
    option :simulation, type: :string, enum: %w[optimistic conversion],
                        desc: "режим симуляции исхода (по умолчанию из политики)"
    option :seed, type: :numeric, desc: "seed для режима conversion"
    option :timeout, type: :string, enum: %w[cascade hold],
                     desc: "таймаут: cascade — к следующему провайдеру (ТЗ), hold — оставить заявку и удержать ёмкость"
    option :on_invalid, type: :string, enum: %w[fail skip], default: "fail",
                        desc: "неразобранная заявка: fail — остановиться, skip — пропустить и отроутить остальные"
    option :html, type: :boolean, default: true, desc: "писать routing_report.html"
    option :quiet, type: :boolean, default: false, desc: "только пути к файлам"
    def route
      run = runner.call(options[:queue])
      run.warnings.each { |warning| say_warning("предупреждение: #{warning}") }
      written = write_run(run, options[:out], options[:suffix], html: options[:html])
      print_summary(run) unless options[:quiet]
      written.each { |label, path| say "#{label} #{path}", :green }
    rescue PayoutRouter::InputError => e
      fail_with(e, hint: e.skippable && SKIP_HINT)
    rescue PayoutRouter::Error => e
      fail_with(e)
    end

    desc "explain OPERATION_ID", "Разобрать решение по одной заявке: кого рассмотрели, кого выбрали и почему"
    option :queue, type: :string, default: DEFAULT_QUEUE, desc: "очередь заявок (JSON)"
    option :simulation, type: :string, enum: %w[optimistic conversion]
    option :seed, type: :numeric
    option :timeout, type: :string, enum: %w[cascade hold]
    option :verbose, type: :boolean, default: false, desc: "показать разложение скора для всех кандидатов"
    option :why_not, type: :string, desc: "показать только попытку указанного провайдера"
    def explain(operation_id)
      run = runner.call(options[:queue])
      decision = run.decision(operation_id)
      raise InputError, "заявки #{operation_id} нет в #{options[:queue]}" unless decision

      Output::Explanation.new(decision, verbose: options[:verbose], only: options[:why_not]).lines.each { |line| say line }
    rescue PayoutRouter::Error => e
      fail_with(e)
    end

    desc "validate DECISIONS", "Проверить файл решений: структура, покрытие очереди, допустимость провайдеров, эталоны"
    option :queue, type: :string, default: DEFAULT_QUEUE, desc: "очередь, по которой строились решения"
    option :reference, type: :string, desc: "эталонные решения организаторов (reference_decisions.json)"
    option :on_invalid, type: :string, enum: %w[fail skip], default: "fail",
                        desc: "битая заявка в очереди: fail — остановиться, skip — карантин (как у route)"
    def validate(decisions_path)
      base = runner
      # Очередь читается теми же правилами, что и при роутинге: иначе прогон с --on-invalid skip
      # проходит, а проверка его результата падает на той же битой заявке.
      operations = base.load_queue(options[:queue])
      result = Validation::DecisionsValidator.new(
        decisions: Inputs::JSONFile.read(decisions_path), operations: operations,
        snapshot: base.snapshot, policy: base.policy,
        reference: options[:reference] && Inputs::JSONFile.read(options[:reference]),
        quarantined: base.rejected_operations
      ).call
      result.checks.each do |check|
        say "#{{ pass: "OK  ", fail: "FAIL", warn: "WARN" }[check.status]} #{check.message}", check_color(check)
      end
      say "итого: пройдено #{result.passed}, ошибок #{result.failed}, предупреждений #{result.warnings}",
          result.ok? ? :green : :red
      exit 1 unless result.ok?
    rescue PayoutRouter::Error => e
      fail_with(e)
    end

    desc "history", "Показатели истории операций по провайдерам"
    def history
      stats = runner.history_stats
      raise InputError, "история пуста или не задана (--history)" if stats.empty?

      print_table(Output::Tables.history(stats))
      say "банки: #{stats.banks.map { |bank, count| "#{bank} #{count}" }.join(", ")}"
      say "Конверсия по сумме чека:", :cyan
      print_table(Output::Tables.history_buckets(stats))
      say "Доверительные интервалы конверсии (Wilson, 95%):", :cyan
      print_table(Output::Tables.history_intervals(stats))
    rescue PayoutRouter::Error => e
      fail_with(e)
    end

    desc "backtest", "Прогнать историю через роутер: ожидаемые одобрения нашего роутинга против фактического"
    option :out, type: :string, default: "out", desc: "каталог результата"
    def backtest
      result = runner.backtest
      path = Output::JSONWriter.write(File.join(options[:out], "backtest_report.json"), result.serialize)
      say "История: #{result.operations} заявок, фактически одобрено #{result.actual_approved}", :cyan
      say "Ожидаемые одобрения (модель по парам провайдер × банк, leave-one-out): " \
          "фактический роутинг #{result.expected_actual.round(1)}, наш #{result.expected_ours.round(1)} " \
          "(#{format("%+.1f", result.uplift)}, #{format("%+.1f%%", result.uplift_pct)})", :green
      say "Перемаршрутизировано: #{result.rerouted} из #{result.operations}; fallback: #{result.fallback}"
      print_table(Output::Tables.backtest(result))
      say "отчёт: #{path}", :green
    rescue PayoutRouter::Error => e
      fail_with(e)
    end

    desc "bound", "Эталонное распределение очереди: сколько одобрений можно было взять и сколько взяли мы"
    option :queue, type: :string, default: DEFAULT_QUEUE, desc: "очередь заявок (JSON)"
    option :synthetic, type: :numeric, default: 0, desc: "вместо очереди — N синтетических заявок из истории"
    option :seed, type: :numeric, default: 1, desc: "seed синтетической очереди"
    option :out, type: :string, default: "out", desc: "каталог результата"
    def bound
      base = runner
      result = base.bound(synthetic_or_queue(base))
      print_table(Output::Tables.bound(result))
      say format("до оптимума %+.2f%%; взяли %.0f%% разброса допустимых назначений; " \
                 "требование держать доли стоило бы ещё %.2f одобрения",
                 result.gap_to_free, result.capture * 100, result.share_cost), :cyan
      path = Output::JSONWriter.write(File.join(options[:out], "assignment_bound.json"), result.serialize)
      say "отчёт: #{path}", :green
    rescue PayoutRouter::Error => e
      fail_with(e)
    end

    desc "compare", "Сравнить политики на одной очереди: доли, отклонение, fallback, ожидаемые одобрения и маржа"
    option :queue, type: :string, default: DEFAULT_QUEUE, desc: "очередь заявок (JSON)"
    option :policies, type: :array, desc: "пути к политикам (по умолчанию --policy и config/policies/*.yml)"
    option :synthetic, type: :numeric, desc: "вместо --queue: N заявок по парам (сумма, банк) из истории"
    option :seed, type: :numeric, desc: "seed синтетической очереди"
    option :out, type: :string, default: "out", desc: "каталог результата"
    def compare
      base = runner
      paths = options[:policies] || [options[:policy], *Dir["config/policies/*.yml"]]
      rows = base.comparison(synthetic_or_queue(base)).call(base.load_policies(paths))
      path = Output::JSONWriter.write(File.join(options[:out], "compare_report.json"), rows.map(&:serialize))
      print_table(Output::Tables.comparison(rows))
      say "отчёт: #{path}", :green
    rescue PayoutRouter::Error => e
      fail_with(e)
    end

    desc "stress", "Стресс-прогон: сценарии давления на роутер — измеренные метрики и проверка инвариантов"
    option :scenario, type: :array, desc: "только эти сценарии (по умолчанию все)"
    option :out, type: :string, default: "out", desc: "каталог результата"
    def stress
      report = runner.stress(options[:scenario])
      print_table(Output::Tables.stress(report.outcomes))
      print_stress_notes(report)
      path = Output::JSONWriter.write(File.join(options[:out], "stress_report.json"), report.serialize)
      say "#{report.outcomes.size} сценариев, #{report.outcomes.sum(&:total)} заявок, " \
          "нарушений инвариантов: #{report.violations.size}; отчёт: #{path}", report.ok? ? :green : :red
      exit 1 unless report.ok?
    rescue PayoutRouter::Error => e
      fail_with(e)
    end

    desc "simulate", "Monte-Carlo: N прогонов очереди с исходами по conversion_24h — разброс одобрений, fallback, долей"
    option :queue, type: :string, default: DEFAULT_QUEUE, desc: "очередь заявок (JSON)"
    option :runs, type: :numeric, default: 200, desc: "число прогонов"
    option :seed, type: :numeric, default: 1, desc: "seed первого прогона"
    option :out, type: :string, default: "out", desc: "каталог результата"
    def simulate
      base = runner
      summary = base.monte_carlo(base.load_queue(options[:queue]), runs: options[:runs], seed: options[:seed])
      path = Output::JSONWriter.write(File.join(options[:out], "simulation_report.json"), summary.serialize)
      print_table(Output::Tables.simulation(summary))
      say "#{summary.runs} прогонов; отчёт: #{path}", :green
    rescue PayoutRouter::Error => e
      fail_with(e)
    end

    desc "tune", "Подобрать веса целей: минимум отклонения от долей, штраф за fallback и низкую ожидаемую конверсию"
    option :queue, type: :string, default: DEFAULT_QUEUE, desc: "очередь для оценки"
    option :synthetic, type: :numeric, default: 0, desc: "вместо очереди — N синтетических заявок из истории"
    option :candidates, type: :numeric, default: 150, desc: "число случайных кандидатов"
    option :seed, type: :numeric, default: 1, desc: "seed поиска"
    option :out, type: :string, default: "out", desc: "каталог результата (policy_tuned.yml)"
    def tune
      base = runner
      operations = synthetic_or_queue(base)
      result = base.tune(operations, candidates: options[:candidates], seed: options[:seed])
      header = "# Подобрано командой tune: #{operations.size} заявок, #{result.evaluations} прогонов роутера."
      path = Output::YAMLWriter.write(File.join(options[:out], "policy_tuned.yml"), result.policy.to_h_document,
                                      header: header)
      print_table(Output::Tables.tuned_goals(base.policy, result))
      print_table(Output::Tables.tuned_objective(result))
      say "политика: #{path}", :green
    rescue PayoutRouter::Error => e
      fail_with(e)
    end

    desc "search", "Перебор конфигураций политики: структурные варианты × веса целей → граница Парето"
    option :queue, type: :string, default: DEFAULT_QUEUE, desc: "очередь в батарее оценки"
    option :synthetic, type: :numeric, default: 200, desc: "размер синтетических очередей батареи"
    option :seeds, type: :string, default: "1,2,3", desc: "seed синтетических очередей через запятую"
    option :samples, type: :numeric, default: 300, desc: "случайных точек симплекса на структурный вариант"
    option :grid, type: :string, default: Search::Space::GRID_GOALS.join(","),
                  desc: "цели исчерпывающей сетки через запятую (4^N точек на вариант; пусто — без сетки)"
    option :seed, type: :numeric, default: 1, desc: "seed перебора"
    option :out, type: :string, default: "out", desc: "каталог результата (search_report.json)"
    def search
      PayoutRouter.eager_load!
      outcome = run_search
      print_table(Output::Tables.search_front(outcome))
      print_table(Output::Tables.search_bests(outcome))
      path = Output::JSONWriter.write(File.join(options[:out], "search_report.json"), outcome.serialize)
      say format("%d конфигураций за %.1f с; на границе Парето %d; доминируют базу %d; отчёт: %s",
                 outcome.evaluations, outcome.elapsed_sec, outcome.front.size, outcome.dominating_base, path), :green
    rescue PayoutRouter::Error => e
      fail_with(e)
    end

    desc "serve", "HTTP-сервис: POST /route принимает заявку и сразу отдаёт решение; GET /report, /state, /metrics"
    option :host, type: :string, default: "127.0.0.1", desc: "адрес"
    option :port, type: :numeric, default: 8080, desc: "порт"
    option :simulation, type: :string, enum: %w[optimistic conversion]
    option :seed, type: :numeric
    def serve
      PayoutRouter.eager_load!
      server = Server.new(Server::Service.new(runner), host: options[:host], port: options[:port])
      say "PayoutRouter слушает http://#{options[:host]}:#{server.port} — POST /route (заявка или массив), " \
          "GET /report, /state, /metrics, /health, POST /reset. Ctrl+C для остановки.", :green
      trap("INT") { server.stop }
      server.start
    rescue PayoutRouter::Error => e
      fail_with(e)
    end

    desc "strategies", "Справочник: hard-правила, цели скоринга (встроенные, плагины, декларативные), пресеты политик"
    def strategies
      policy = runner.policy
      say "Hard-правила (#{Constraints::Registry.keys.size}):", :cyan
      print_table(Constraints::Registry.keys.map { |key| [key, Constraints::Registry.describe(key)] })
      say "Цели скоринга (#{Strategies::Registry.keys.size}):", :cyan
      print_table(Strategies::Registry.keys.map { |key| [key, Strategies::Registry.describe(key)] })
      say "Декларативные цели (custom_goals в YAML, без кода):", :cyan
      print_table(Strategies::Custom.describe.to_a)
      print_policy_extensions(policy)
      say "Пресеты (config/policies):", :cyan
      print_table(Dir["config/policies/*.yml"].map { |path| preset_row(path) })
    rescue PayoutRouter::Error => e
      fail_with(e)
    end

    desc "bench", "Бенчмарк: синтетическая очередь на N заявок через полный конвейер"
    option :operations, type: :numeric, default: 50_000, desc: "число заявок"
    option :seed, type: :numeric, default: 1, desc: "seed генератора очереди"
    def bench
      PayoutRouter.eager_load!
      base = runner
      result = Bench::LoadTest.new(snapshot: base.snapshot, policy: base.policy).run(options[:operations],
                                                                                     seed: options[:seed])
      say "#{result.operations} заявок за #{result.elapsed_sec.round(2)} с — #{result.ops_per_sec.round} заявок/с; " \
          "fallback: #{result.fallback}, повторов: #{result.retries}", :green
    rescue PayoutRouter::Error => e
      fail_with(e)
    end

    desc "version", "Версия"
    def version = say(PayoutRouter::VERSION)

    private

    def runner
      Runner.new(providers_path: options[:providers], policy_path: options[:policy], history_path: history_path,
                 simulation_mode: options[:simulation], seed: options[:seed], timeout: options[:timeout],
                 on_invalid: options[:on_invalid] || "fail")
    end

    def history_path = options[:history].to_s.empty? ? nil : options[:history]

    def run_search
      base = runner
      base.search(base.load_queue(options[:queue]),
                  synthetic: options[:synthetic],
                  seeds: options[:seeds].split(",").map(&:to_i),
                  random_samples: options[:samples],
                  seed: options[:seed],
                  grid_goals: options[:grid].to_s.split(","))
    end

    # Очередь для сравнения и подбора весов: либо файл --queue, либо N синтетических заявок из истории.
    def synthetic_or_queue(base)
      count = options[:synthetic].to_i
      count.positive? ? base.synthetic_queue(count, seed: options[:seed]) : base.load_queue(options[:queue])
    end

    def write_run(run, out, suffix, html:)
      written = [
        ["решения:",
         Output::JSONWriter.write(File.join(out, "routing_decisions#{suffix}.json"), run.serialized_decisions)],
        ["отчёт:  ", Output::JSONWriter.write(File.join(out, "routing_report#{suffix}.json"), run.report)]
      ]
      written << ["дашборд:", Output::HtmlReport.new(run).write(File.join(out, "routing_report#{suffix}.html"))] if html
      # В optimistic отказов в решениях нет по построению — рядом кладём прогон с отказами (эксперты на
      # чекпоинте 3: «покажите пример, где есть отказ и переход»). Имя нарочно не routing_decisions*, чтобы
      # автопроверка не приняла его за сдаваемый файл.
      if run.cascade
        path = File.join(out, "routing_cascade_demo#{suffix}.json")
        written << ["каскад: ", Output::JSONWriter.write(path, run.serialized_cascade)]
      end
      written
    end

    def print_summary(run)
      summary = Output::Summary.new(run)
      say summary.headline, :cyan
      print_table(summary.distribution_rows)
      summary.result_lines.each { |line| say line }
      summary.recommendation_lines.each { |line| say line, :yellow }
    end

    def print_stress_notes(report)
      report.outcomes.each { |outcome| say "  #{outcome.key}: #{outcome.scenario.note}" if outcome.scenario.note }
      report.outcomes.reject(&:ok?).each do |outcome|
        outcome.violations.each { |violation| say_warning("#{outcome.key} ✗ #{violation}") }
      end
    end

    def print_policy_extensions(policy)
      say "Политика #{policy.name}: #{policy.selection_label}", :cyan
      say "  плагины: #{policy.plugins.empty? ? "нет" : policy.plugins.join(", ")}"
      custom = policy.custom_goals.map { |key, goal| "#{key} (#{goal.type})" }
      say "  свои цели: #{custom.empty? ? "нет" : custom.join(", ")}"
    end

    def preset_row(path)
      preset = Inputs::PolicyLoader.load(path)
      [File.basename(path, ".yml"), preset.selection.mode, preset.description.to_s.gsub(/\s+/, " ")[0, 90]]
    rescue PayoutRouter::Error => e
      [File.basename(path, ".yml"), "ошибка", e.message[0, 90]]
    end

    def check_color(check) = { pass: :green, fail: :red, warn: :yellow }[check.status]

    # Диагностика идёт напрямую в $stderr, а не через say/say_error: Thor глушит их при --quiet,
    # а «заявка пропущена» и «файл не найден» должны быть видны всегда — иначе упавшая
    # или неполная команда не скажет ни слова, только код возврата.
    def say_warning(text) = warn(shell.set_color(text, :yellow))

    def fail_with(error, hint: nil)
      warn shell.set_color("ошибка: #{error.message}", :red)
      say_warning("подсказка: #{hint}") if hint
      exit 2
    end
  end
end
