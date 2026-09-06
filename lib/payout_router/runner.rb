# frozen_string_literal: true

module PayoutRouter
  # Сценарий «загрузить входы → отроутить очередь → собрать отчёт». CLI лишь оборачивает его.
  class Runner
    # cascade — Analytics::CascadeDemo::Result или nil: второй прогон с отказами, когда сдаваемый шёл в optimistic.
    # optimality — Analytics::AssignmentBound::Result: наш онлайн-роутинг против точного оптимума очереди.
    Run = Data.define(:snapshot, :policy, :operations, :decisions, :ledger, :report,
                      :history_stats, :simulation, :warnings, :cascade, :optimality) do
      def decision(operation_id) = decisions.find { |decision| decision.operation_id == operation_id }
      def serialized_decisions = decisions.map(&:serialize)

      # Файл-демонстрация каскада: тот же формат решений, что и routing_decisions, плюс пояснение и seed —
      # для проверяющего, который открывает только JSON решений и в optimistic-файле отказов не увидит.
      def serialized_cascade
        return nil if cascade.nil?

        cascade.summary.slice("note", "simulation", "operations")
               .merge("decisions" => cascade.decisions.map(&:serialize))
      end
    end

    def initialize(providers_path:, policy_path:, history_path: nil, simulation_mode: nil, seed: nil, timeout: nil,
                   on_invalid: :fail)
      @providers_path = providers_path
      @policy_path = policy_path
      @history_path = history_path
      @simulation_mode = simulation_mode
      @seed = seed
      @timeout = timeout
      @on_invalid = on_invalid
      @rejected_operations = []
    end

    # Заявки, ушедшие в карантин при последней загрузке очереди (on_invalid: skip).
    attr_reader :rejected_operations

    # Политика из файла плюс переопределения симуляции из командной строки — чтобы роутер,
    # симулятор и отчёт видели одни и те же настройки, а не файл против флагов.
    def policy = @policy ||= override_simulation(Inputs::PolicyLoader.load(@policy_path))

    # Снимок без наложенной политики — для сравнения нескольких политик на одних данных.
    def raw_snapshot = @raw_snapshot ||= Inputs::ProvidersLoader.load(@providers_path)

    def snapshot = @snapshot ||= policy.apply(raw_snapshot)

    def history_records = @history_records ||= @history_path ? Inputs::HistoryLoader.load(@history_path) : []

    def history_stats = @history_stats ||= Analytics::HistoryStats.new(history_records)

    def simulation = policy.simulation

    def load_queue(queue_path)
      loader = Inputs::QueueLoader.new(Inputs::JSONFile.read(queue_path),
                                       source: queue_path,
                                       default_time: snapshot.snapshot_at,
                                       on_invalid: @on_invalid)
      operations = loader.call
      @rejected_operations = loader.rejected
      operations
    end

    def load_policies(paths) = paths.map { |path| Inputs::PolicyLoader.load(path) }

    def call(queue_path)
      operations = load_queue(queue_path)
      route(operations)
    end

    def route(operations)
      simulator = Simulation.build(simulation, history_stats: history_stats)
      result = Routing::BatchRouter.new(snapshot: snapshot, policy: policy, simulator: simulator,
                                        history: history_stats).call(operations)
      cascade = cascade_demo(operations)
      optimality = assignment_bound(operations, result.decisions)
      report = Analytics::ReportBuilder.new(decisions: result.decisions, ledger: result.ledger, snapshot: snapshot,
                                            policy: policy, history_stats: history_stats, simulation: simulation,
                                            cascade: cascade, optimality: optimality).build
      Run.new(snapshot: snapshot, policy: policy, operations: operations, decisions: result.decisions,
              ledger: result.ledger, report: report, history_stats: history_stats, simulation: simulation,
              warnings: warnings, cascade: cascade, optimality: optimality)
    end

    # Стресс-прогон: сценарии строятся от сырого снимка — политика накладывается внутри каталога.
    def stress(keys = nil)
      catalog = Stress::Catalog.new(snapshot: raw_snapshot, policy: policy)
      Stress::Suite.new(catalog, history: history_stats).call(keys)
    end

    def backtest
      Analytics::Backtest.new(records: history_records, snapshot: snapshot, policy: policy, history: history_stats).call
    end

    # Эталонное распределение очереди: наш роутинг против оптимального назначения. Считается
    # в каждом прогоне и лежит в отчёте, так что отдельная команда просто достаёт готовый результат.
    def bound(operations) = route(operations).optimality

    # Пустая очередь эталона не имеет: сравнивать нечего, а min-cost flow на нуле банков вырождается.
    def assignment_bound(operations, decisions)
      return nil if operations.empty?

      Analytics::AssignmentBound.new(snapshot: snapshot, policy: policy, history: history_stats,
                                     operations: operations, decisions: decisions).call
    end

    def comparison(operations)
      Analytics::PolicyComparison.new(base_snapshot: raw_snapshot, operations: operations, history: history_stats)
    end

    def monte_carlo(operations, runs:, seed:)
      Analytics::MonteCarlo.new(snapshot: snapshot, policy: policy, operations: operations, history: history_stats,
                                runs: runs, seed: seed).call
    end

    # Перебор конфигураций политики. Батарея — переданная очередь плюс синтетические очереди
    # на нескольких seed: политика, подобранная на одной очереди, обычно на ней же и переобучена.
    def search(operations, synthetic:, seeds:, random_samples:, seed: 1, grid_goals: Search::Space::GRID_GOALS)
      queues = { "queue" => operations }
      seeds.each { |item| queues["syn#{synthetic}_s#{item}"] = synthetic_queue(synthetic, seed: item) }
      battery = Search::Battery.new(base_snapshot: raw_snapshot, history: history_stats,
                                    queues: queues, records: history_records)
      Search::Engine.new(battery: battery, policy: policy, random_samples: random_samples, seed: seed,
                         grid_goals: grid_goals).call
    end

    def tune(operations, candidates:, seed:)
      Analytics::WeightTuner.new(comparison: comparison(operations), policy: policy, candidates: candidates,
                                 seed: seed).call
    end

    # Очередь для подбора весов: реальные пары (сумма, банк) из истории, интервалы 1–5 секунд.
    def synthetic_queue(count, seed:)
      Bench::QueueGenerator.from_history(history_records, seed: seed, start_at: snapshot.snapshot_at || Time.now)
                           .generate(count)
    end

    def warnings
      list = policy.unknown_providers(snapshot).map do |name|
        "политика упоминает провайдера #{name}, которого нет в providers.json"
      end
      if policy.fallback_provider && snapshot.fallback.nil?
        list << "fallback-провайдер #{policy.fallback_provider} отсутствует в providers.json — " \
                "заявки без допустимых провайдеров останутся без маршрута"
      end
      list + rejected_warnings
    end

    # Заявки в карантине (on_invalid: skip): их нет в решениях, и это надо увидеть, а не проглядеть.
    def rejected_warnings
      @rejected_operations.map do |rejected|
        id = rejected.operation_id || "позиция #{rejected.index}"
        "заявка #{id} не разобрана и пропущена (on_invalid: skip): #{rejected.message}"
      end
    end

    private

    # В optimistic отказов в решениях нет по построению — отчёт несёт отдельный прогон с отказами.
    # В conversion каскад и так в самих решениях, второй прогон не нужен.
    def cascade_demo(operations)
      return nil unless simulation.mode == "optimistic"

      Analytics::CascadeDemo.new(snapshot: snapshot, policy: policy, operations: operations,
                                 history: history_stats, seed: simulation.seed).call
    end

    def override_simulation(loaded)
      settings = loaded.simulation
      loaded.with(simulation: settings.with(mode: @simulation_mode || settings.mode,
                                            seed: @seed || settings.seed,
                                            timeout: @timeout || settings.timeout))
    end
  end
end
