# frozen_string_literal: true

module PayoutRouter
  module Analytics
    # Monte-Carlo: N прогонов очереди в режиме conversion с разными seed. Показывает разброс
    # одобрений, fallback, повторов и долей — «что будет в среднем и в плохой день».
    class MonteCarlo
      Summary = Data.define(:runs, :approved, :fallback, :retries, :shares) do
        def serialize
          { "runs" => runs, "approved" => approved, "fallback" => fallback, "retries" => retries,
            "shares_pct" => shares }
        end
      end

      def initialize(snapshot:, policy:, operations:, history:, runs: 200, seed: 1)
        @snapshot = snapshot
        @policy = policy
        @operations = operations
        @history = history
        @runs = runs
        @seed = seed
      end

      def call
        approved = []
        fallback = []
        retries = []
        shares = Hash.new { |hash, name| hash[name] = [] }
        @runs.times do |index|
          decisions = run(@seed + index)
          approved << decisions.count(&:approved?)
          fallback << decisions.count(&:fallback_used)
          retries << decisions.sum(&:retries)
          collect_shares(decisions, shares)
        end
        Summary.new(runs: @runs, approved: describe(approved), fallback: describe(fallback), retries: describe(retries),
                    shares: shares.sort.to_h { |name, values| [name, describe(values)] })
      end

      private

      def run(seed)
        simulator = Simulation::Conversion.new(seed: seed, history_stats: @history)
        Routing::BatchRouter.new(snapshot: @snapshot, policy: @policy, simulator: simulator, history: @history)
                            .call(@operations).decisions
      end

      def collect_shares(decisions, shares)
        routed = decisions.count(&:routed?)
        @snapshot.providers.each do |provider|
          count = decisions.count { |decision| decision.selected_provider == provider.name }
          shares[provider.name] << (routed.zero? ? 0.0 : count * 100.0 / routed)
        end
      end

      # Среднее и перцентили: p5 — «плохой день», p95 — «хороший».
      def describe(values)
        sorted = values.sort
        {
          "mean" => (sorted.sum.to_f / sorted.size).round(2),
          "min" => sorted.first, "p5" => percentile(sorted, 5), "p50" => percentile(sorted, 50),
          "p95" => percentile(sorted, 95), "max" => sorted.last
        }
      end

      def percentile(sorted, pct)
        index = ((pct / 100.0) * (sorted.size - 1)).round
        value = sorted[index]
        value.is_a?(Float) ? value.round(2) : value
      end
    end
  end
end
