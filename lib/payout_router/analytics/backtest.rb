# frozen_string_literal: true

module PayoutRouter
  module Analytics
    # Бэктест на истории: прогоняем исторические заявки через наш роутер и сравниваем
    # ожидаемое число одобрений с тем, что дал фактический роутинг. Вероятность одобрения —
    # из ApprovalModel с leave-one-out: сама заявка в оценке пары провайдер × банк не участвует,
    # чтобы не «подглядывать» в ответ. Оценка модельная, но для обоих вариантов одинаковая.
    class Backtest
      Result = Data.define(:operations, :actual_approved, :expected_actual, :expected_ours, :rerouted,
                           :fallback, :by_provider, :decisions) do
        def uplift = expected_ours - expected_actual
        def uplift_pct = expected_actual.zero? ? 0.0 : uplift * 100.0 / expected_actual

        def serialize
          {
            "operations" => operations,
            "actual_approved" => actual_approved,
            "expected_approved_actual_routing" => expected_actual.round(2),
            "expected_approved_our_routing" => expected_ours.round(2),
            "uplift_approvals" => uplift.round(2),
            "uplift_pct" => uplift_pct.round(1),
            "rerouted_operations" => rerouted,
            "fallback_operations" => fallback,
            "by_provider" => by_provider,
            "method" => "leave-one-out smoothed approval rate per provider × bank; daily counters reset to start of day"
          }
        end
      end

      # Накопитель по провайдерам: сколько заявок и ожидаемых одобрений в факте и у нас.
      class Tally
        attr_reader :expected_actual, :expected_ours, :rerouted

        def initialize
          @totals = Hash.new do |hash, name|
            hash[name] = { "actual" => 0, "ours" => 0, "expected_actual" => 0.0, "expected_ours" => 0.0 }
          end
          @expected_actual = @expected_ours = 0.0
          @rerouted = 0
        end

        def add(record, decision, p_actual, p_ours)
          @expected_actual += p_actual
          @expected_ours += p_ours
          @rerouted += 1 if decision.selected_provider != record.provider
          @totals[record.provider]["actual"] += 1
          @totals[record.provider]["expected_actual"] += p_actual
          return unless decision.routed?

          @totals[decision.selected_provider]["ours"] += 1
          @totals[decision.selected_provider]["expected_ours"] += p_ours
        end

        def by_provider
          @totals.sort.to_h do |name, values|
            [name, values.transform_values { |value| value.is_a?(Float) ? value.round(2) : value }]
          end
        end
      end

      def initialize(records:, snapshot:, policy:, history:)
        @records = records
        @snapshot = snapshot
        @policy = policy
        @history = history
        @model = ApprovalModel.new(history: history, snapshot: snapshot)
      end

      def call
        raise InputError, "история пуста — бэктест не на чем считать" if @records.empty?

        result = Routing::BatchRouter.new(snapshot: fresh_day(@snapshot), policy: @policy,
                                          simulator: Simulation::Optimistic.new, history: @history).call(operations)
        tally = Tally.new
        @records.zip(result.decisions) do |record, decision|
          tally.add(record, decision, *probabilities(record, decision))
        end
        Result.new(operations: @records.size, actual_approved: @records.count(&:approved?),
                   expected_actual: tally.expected_actual, expected_ours: tally.expected_ours, rerouted: tally.rerouted,
                   fallback: result.decisions.count(&:fallback_used), by_provider: tally.by_provider,
                   decisions: result.decisions)
      end

      private

      def operations
        base = @snapshot.snapshot_at || Time.now
        @records.each_with_index.map do |record, index|
          Domain::Operation.new(operation_id: record.operation_id, created_at: record.created_at || (base + index),
                                amount: record.amount, bank: record.bank)
        end
      end

      # История — за прошлый день, поэтому стартуем с чистыми дневными счётчиками.
      def fresh_day(snapshot)
        snapshot.with(providers: snapshot.providers.map do |provider|
          provider.with(daily_approved_amount: 0, in_progress_count: 0, in_progress_amount: 0)
        end)
      end

      def probabilities(record, decision)
        p_actual = @model.probability(record.provider, record.bank, exclude: record)
        p_ours = decision.routed? ? @model.probability(decision.selected_provider, record.bank, exclude: record) : 0.0
        [p_actual, p_ours]
      end
    end
  end
end
