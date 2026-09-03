# frozen_string_literal: true

module PayoutRouter
  module Analytics
    # Собирает routing_report.json: обязательные разделы формата организаторов
    # (period, total_operations, distribution, skip_reasons, projected_daily_utilization,
    # recommendations) плюс расширенная аналитика.
    class ReportBuilder
      def initialize(decisions:, ledger:, snapshot:, policy:, history_stats:, simulation:)
        @decisions = decisions
        @snapshot = snapshot
        @policy = policy
        @history = history_stats
        @simulation = simulation
        @stats = RoutingStats.new(decisions: decisions, ledger: ledger, snapshot: snapshot)
      end

      def build
        recommendations = Recommendations::Engine.new.call(
          Recommendations::Context.new(stats: @stats, history: @history, snapshot: @snapshot, policy: @policy)
        )
        header.merge(body).merge(
          "history_analysis" => history_section,
          "recommendations" => recommendations.map(&:message),
          "recommendation_details" => recommendations.map(&:serialize)
        )
      end

      private

      def header
        {
          "period" => period,
          "snapshot_at" => @snapshot.snapshot_at&.iso8601,
          "gateway" => @snapshot.gateway,
          "merchant" => @snapshot.merchant,
          "policy" => {
            "name" => @policy.name,
            "description" => @policy.description,
            "goals" => @policy.enabled_goals,
            "hard_constraints" => @policy.hard_constraints,
            "tie_breakers" => @policy.tie_breakers,
            "fallback_provider" => @policy.fallback_provider
          },
          "simulation" => { "mode" => @simulation.mode, "seed" => @simulation.seed }
        }
      end

      def body
        {
          "total_operations" => @stats.total,
          "routed_operations" => @stats.routed,
          "fallback_operations" => @stats.fallback_count,
          "unrouted_operations" => @stats.unrouted,
          "distribution" => @stats.distribution,
          "results" => @stats.results,
          "skip_reasons" => @stats.skip_reasons,
          "skip_reasons_by_provider" => @stats.skip_reasons_by_provider,
          "projected_daily_utilization" => @stats.utilization,
          "attempts" => @stats.attempts_stats,
          "target_attainability" => @stats.attainability
        }
      end

      def period
        first = @decisions.filter_map { |decision| decision.operation.created_at }.min || @snapshot.snapshot_at
        first&.strftime("%Y-%m-%d")
      end

      def history_section
        return nil if @history.empty?

        @history.serialize.merge("conversion_drift" => conversion_drift)
      end

      # Заявленная conversion_24h против наблюдаемой в истории; significant — вне 95% интервала Уилсона.
      def conversion_drift
        @snapshot.external.filter_map do |provider|
          observed = @history.conversion(provider.name)
          next if observed.nil?

          interval = @history.conversion_interval(provider.name)
          [provider.name, { "reported" => provider.conversion_24h, "observed" => observed.round(3),
                            "delta" => (observed - provider.conversion_24h.to_f).round(3),
                            "interval_95" => interval,
                            "significant" => !provider.conversion_24h.to_f.between?(interval.first, interval.last) }]
        end.to_h
      end
    end
  end
end
