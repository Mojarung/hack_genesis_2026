# frozen_string_literal: true

module PayoutRouter
  module Stress
    # Прогон стресс-сценариев: каждый гоняется через настоящий конвейер (тот же BatchRouter,
    # что и на сдаче), после чего снимаются метрики и проверяются инварианты.
    class Suite
      Report = Data.define(:outcomes) do
        def ok? = outcomes.all?(&:ok?)
        def violations = outcomes.flat_map(&:violations)
        def outcome(key) = outcomes.find { |item| item.key == key.to_sym }

        def serialize
          { "scenarios" => outcomes.size, "operations" => outcomes.sum(&:total),
            "invariant_violations" => violations.size, "results" => outcomes.map(&:serialize) }
        end
      end

      # history — та же статистика истории, что и на сдаче: без неё цели на модели одобрения
      # (conversion, bank_affinity) считались бы по другому скореру, и стресс мерил бы не то,
      # что реально уходит жюри.
      def initialize(catalog, history: nil)
        @catalog = catalog
        @history = history
      end

      def call(keys = nil)
        scenarios = keys.nil? || keys.empty? ? @catalog.all : Array(keys).map { |key| @catalog.fetch(key) }
        Report.new(outcomes: scenarios.map { |scenario| execute(scenario) })
      end

      private

      # Дневной лимит можно требовать как инвариант только там, где политика его резервирует.
      def reserves_daily_limit?(policy)
        policy.hard_constraints.include?(Constraints::DailyLimitReserved.key)
      end

      def execute(scenario)
        router = Routing::BatchRouter.new(snapshot: scenario.snapshot, policy: scenario.policy,
                                          simulator: scenario.simulator, history: @history)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = router.call(scenario.operations, &scenario.before_each)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

        Outcome.new(
          scenario: scenario, ledger: result.ledger, elapsed_sec: elapsed,
          stats: Analytics::RoutingStats.new(decisions: result.decisions, ledger: result.ledger,
                                             snapshot: scenario.snapshot),
          violations: Invariants.check(decisions: result.decisions, operations: scenario.operations,
                                       ledger: result.ledger, snapshot: scenario.snapshot,
                                       allow_unrouted: scenario.allow_unrouted,
                                       enforce_daily_limit: reserves_daily_limit?(scenario.policy))
        )
      end
    end
  end
end
