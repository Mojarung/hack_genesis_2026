# frozen_string_literal: true

require "thor"

module PayoutRouter
  # Командная строка. Логика — в Runner и Output, здесь только разбор опций и печать.
  class CLI < Thor
    package_name "payout_router"

    def self.exit_on_failure? = true

    class_option :providers, type: :string, default: "data/providers.json", desc: "снимок провайдеров (providers.json)"
    class_option :history, type: :string, default: "data/operations_history.csv",
                           desc: "история операций (CSV); пустая строка — без истории"
    class_option :policy, type: :string, default: "config/policy.yml", desc: "политика маршрутизации (YAML)"

    desc "route", "Распределить очередь заявок: routing_decisions.json + routing_report.json"
    option :queue, type: :string, default: "data/operations_queue_10.json", desc: "очередь заявок (JSON)"
    option :out, type: :string, default: "out", desc: "каталог результата"
    option :suffix, type: :string, default: "", desc: "суффикс имён файлов, например _test"
    option :simulation, type: :string, enum: %w[optimistic conversion],
                        desc: "режим симуляции исхода (по умолчанию из политики)"
    option :seed, type: :numeric, desc: "seed для режима conversion"
    option :quiet, type: :boolean, default: false, desc: "только пути к файлам"
    def route
      run = runner.call(options[:queue])
      run.warnings.each { |warning| say "предупреждение: #{warning}", :yellow }
      decisions_path = Output::JSONWriter.write(File.join(options[:out], "routing_decisions#{options[:suffix]}.json"),
                                                run.serialized_decisions)
      report_path = Output::JSONWriter.write(File.join(options[:out], "routing_report#{options[:suffix]}.json"),
                                             run.report)
      print_summary(run) unless options[:quiet]
      say "решения: #{decisions_path}", :green
      say "отчёт:   #{report_path}", :green
    rescue PayoutRouter::Error => e
      fail_with(e)
    end

    desc "explain OPERATION_ID", "Разобрать решение по одной заявке: кого рассмотрели, кого выбрали и почему"
    option :queue, type: :string, default: "data/operations_queue_10.json", desc: "очередь заявок (JSON)"
    option :simulation, type: :string, enum: %w[optimistic conversion]
    option :seed, type: :numeric
    option :verbose, type: :boolean, default: false, desc: "показать разложение скора для всех кандидатов"
    def explain(operation_id)
      run = runner.call(options[:queue])
      decision = run.decision(operation_id)
      raise InputError, "заявки #{operation_id} нет в #{options[:queue]}" unless decision

      Output::Explanation.new(decision, verbose: options[:verbose]).lines.each { |line| say line }
    rescue PayoutRouter::Error => e
      fail_with(e)
    end

    desc "validate DECISIONS", "Проверить файл решений: структура, покрытие очереди, допустимость провайдеров, эталоны"
    option :queue, type: :string, default: "data/operations_queue_10.json",
                   desc: "очередь, по которой строились решения"
    option :reference, type: :string, desc: "эталонные решения организаторов (reference_decisions.json)"
    def validate(decisions_path)
      base = runner
      result = Validation::DecisionsValidator.new(
        decisions: Inputs::JSONFile.read(decisions_path), operations: base.load_queue(options[:queue]),
        snapshot: base.snapshot, policy: base.policy,
        reference: options[:reference] && Inputs::JSONFile.read(options[:reference])
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

      rows = stats.providers.map do |name|
        provider = stats.serialize["providers"][name]
        [name, provider["operations"], "#{provider["count_share_pct"]}%", "#{provider["volume_share_pct"]}%",
         provider["conversion"], "#{provider["rejected_pct"]}%", "#{provider["expired_pct"]}%",
         provider["avg_latency_sec"]]
      end
      print_table([%w[провайдер операций доля доля_объёма конверсия отказы таймауты задержка], *rows])
      say "банки: #{stats.banks.map { |bank, count| "#{bank} #{count}" }.join(", ")}"
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
                 simulation_mode: options[:simulation], seed: options[:seed])
    end

    def history_path = options[:history].to_s.empty? ? nil : options[:history]

    def print_summary(run)
      summary = Output::Summary.new(run)
      say summary.headline, :cyan
      print_table(summary.distribution_rows)
      summary.result_lines.each { |line| say line }
      summary.recommendation_lines.each { |line| say line, :yellow }
    end

    def check_color(check) = { pass: :green, fail: :red, warn: :yellow }[check.status]

    def fail_with(error)
      say_error "ошибка: #{error.message}", :red
      exit 2
    end
  end
end
