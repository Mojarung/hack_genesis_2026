# frozen_string_literal: true

module PayoutRouter
  module Search
    # Батарея оценки: одни и те же очереди и одна и та же история для всех кандидатов.
    # Смысл в повторяемости — политика, подобранная на одной очереди, обычно на ней же и переобучена,
    # поэтому очередей несколько, а для честной проверки батарея создаётся ещё раз на других seed.
    class Battery
      def initialize(base_snapshot:, history:, queues:, records: [])
        @base_snapshot = base_snapshot
        @history = history
        @queues = queues
        @records = records
        @comparisons = queues.transform_values do |operations|
          Analytics::PolicyComparison.new(base_snapshot: base_snapshot, operations: operations, history: history)
        end
      end

      def queue_names = @queues.keys

      def call(policy)
        rows = @comparisons.map { |name, comparison| [name, comparison.evaluate(policy)] }
        deviations = rows.map { |_name, row| row.deviation_pp }
        Metrics.new(deviation_pp: mean(deviations), worst_deviation_pp: deviations.max.to_f,
                    conversion: mean(rows.map { |_name, row| row.expected_conversion }),
                    margin_per_op: mean(rows.map { |name, row| row.expected_margin / size(name) }),
                    fallback_rate: mean(rows.map { |name, row| row.fallback.to_f / size(name) }),
                    unrouted_rate: mean(rows.map { |name, row| unrouted(name, row) }),
                    backtest_uplift_pct: backtest(policy))
      end

      private

      def size(name) = [@queues.fetch(name).size, 1].max

      def unrouted(name, row)
        routed = row.distribution.values.sum { |share| share["count"].to_i }
        (size(name) - routed).to_f / size(name)
      end

      def backtest(policy)
        return 0.0 if @records.empty?

        Analytics::Backtest.new(records: @records, snapshot: policy.apply(@base_snapshot),
                                policy: policy, history: @history).call.uplift_pct
      end

      def mean(values) = values.empty? ? 0.0 : values.sum.to_f / values.size
    end
  end
end
