# frozen_string_literal: true

module PayoutRouter
  module Analytics
    # Одна очередь — несколько политик: распределение, отклонение от целей, fallback,
    # ожидаемые одобрения (по модели одобрения) и ожидаемая маржа. Что-если до продакшена.
    class PolicyComparison
      Row = Data.define(:policy, :distribution, :deviation_pp, :fallback, :retries, :expected_approvals,
                        :expected_conversion, :expected_margin, :avg_latency_sec) do
        def serialize
          {
            "policy" => policy.name, "distribution" => distribution, "deviation_pp_total" => deviation_pp.round(1),
            "fallback_operations" => fallback, "retries" => retries,
            "expected_approvals" => expected_approvals.round(2), "expected_conversion" => expected_conversion.round(3),
            "expected_margin_rub" => expected_margin.round(2), "avg_latency_sec" => avg_latency_sec.round(1)
          }
        end
      end

      def initialize(base_snapshot:, operations:, history:, simulator: Simulation::Optimistic.new)
        @base_snapshot = base_snapshot
        @operations = operations
        @history = history
        @simulator = simulator
      end

      def call(policies) = policies.map { |policy| evaluate(policy) }

      # Метрики одной политики — их же использует подбор весов.
      def evaluate(policy)
        snapshot = policy.apply(@base_snapshot)
        result = Routing::BatchRouter.new(snapshot: snapshot, policy: policy, simulator: @simulator,
                                          history: @history).call(@operations)
        stats = RoutingStats.new(decisions: result.decisions, ledger: result.ledger, snapshot: snapshot)
        approvals, margin = expectations(result.decisions, snapshot)
        Row.new(policy: policy, distribution: distribution(stats), deviation_pp: deviation(stats, snapshot),
                fallback: stats.fallback_count, retries: stats.retries, expected_approvals: approvals,
                expected_conversion: @operations.empty? ? 0.0 : approvals / @operations.size,
                expected_margin: margin, avg_latency_sec: average_latency(result.decisions))
      end

      private

      def distribution(stats)
        stats.distribution.transform_values { |share| share.slice("count", "share_pct", "target_pct", "deviation_pp") }
      end

      def deviation(stats, snapshot)
        snapshot.external.sum { |provider| stats.distribution.dig(provider.name, "deviation_pp").to_f.abs }
      end

      def average_latency(decisions)
        decisions.empty? ? 0.0 : decisions.sum(&:latency_sec).to_f / decisions.size
      end

      # Ожидаемые одобрения и маржа: Σ p(провайдер, банк) и Σ p × сумма × (маржа мерчанта − маржа провайдера).
      def expectations(decisions, snapshot)
        model = ApprovalModel.new(history: @history, snapshot: snapshot)
        approvals = 0.0
        margin = 0.0
        decisions.select(&:routed?).each do |decision|
          provider = snapshot.provider(decision.selected_provider)
          probability = model.probability(provider.name, decision.operation.bank)
          approvals += probability
          margin += probability * decision.operation.amount * margin_pct(provider) / 100.0
        end
        [approvals, margin]
      end

      def margin_pct(provider) = provider.merchant_margin_pct.to_f - provider.provider_margin_pct.to_f
    end
  end
end
