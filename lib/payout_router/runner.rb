# frozen_string_literal: true

module PayoutRouter
  # Сценарий «загрузить входы → отроутить очередь → собрать отчёт». CLI лишь оборачивает его.
  class Runner
    Run = Data.define(:snapshot, :policy, :operations, :decisions, :ledger, :report,
                      :history_stats, :simulation, :warnings) do
      def decision(operation_id) = decisions.find { |decision| decision.operation_id == operation_id }
      def serialized_decisions = decisions.map(&:serialize)
    end

    def initialize(providers_path:, policy_path:, history_path: nil, simulation_mode: nil, seed: nil)
      @providers_path = providers_path
      @policy_path = policy_path
      @history_path = history_path
      @simulation_mode = simulation_mode
      @seed = seed
    end

    def policy = @policy ||= Inputs::PolicyLoader.load(@policy_path)

    def snapshot = @snapshot ||= policy.apply(Inputs::ProvidersLoader.load(@providers_path))

    def history_stats
      @history_stats ||= Analytics::HistoryStats.new(@history_path ? Inputs::HistoryLoader.load(@history_path) : [])
    end

    def simulation
      @simulation ||= policy.simulation.with(mode: @simulation_mode || policy.simulation.mode,
                                             seed: @seed || policy.simulation.seed)
    end

    def load_queue(queue_path) = Inputs::QueueLoader.load(queue_path, default_time: snapshot.snapshot_at)

    def call(queue_path)
      operations = load_queue(queue_path)
      route(operations)
    end

    def route(operations)
      simulator = Simulation.build(simulation, history_stats: history_stats)
      result = Routing::BatchRouter.new(snapshot: snapshot, policy: policy, simulator: simulator).call(operations)
      report = Analytics::ReportBuilder.new(decisions: result.decisions, ledger: result.ledger, snapshot: snapshot,
                                            policy: policy, history_stats: history_stats, simulation: simulation).build
      Run.new(snapshot: snapshot, policy: policy, operations: operations, decisions: result.decisions,
              ledger: result.ledger, report: report, history_stats: history_stats, simulation: simulation,
              warnings: warnings)
    end

    def warnings
      list = policy.unknown_providers(snapshot).map do |name|
        "политика упоминает провайдера #{name}, которого нет в providers.json"
      end
      if policy.fallback_provider && snapshot.fallback.nil?
        list << "fallback-провайдер #{policy.fallback_provider} отсутствует в providers.json — " \
                "заявки без допустимых провайдеров останутся без маршрута"
      end
      list
    end
  end
end
