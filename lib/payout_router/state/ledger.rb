# frozen_string_literal: true

module PayoutRouter
  module State
    # Состояние всех провайдеров + виртуальные часы. Роутер спрашивает у леджера доли и загрузку,
    # а после каждой заявки сообщает ему, кому и с каким исходом она ушла.
    class Ledger
      Settlement = Data.define(:state, :operation, :outcome)

      attr_reader :states, :selected_total, :selected_amount_total

      def initialize(snapshot)
        @states = snapshot.providers.to_h { |provider| [provider.name, ProviderState.new(provider)] }.freeze
        @external = @states.values.select { |state| state.provider.external? }.freeze
        @fallback = @states.values.find { |state| state.provider.fallback? }
        @pending = SettlementQueue.new
        @selected_total = 0
        @selected_amount_total = 0
      end

      def state(name) = @states.fetch(name) { raise Error, "нет состояния провайдера #{name}" }
      def external_states = @external
      def fallback_state = @fallback

      # Заявка ушла провайдеру; ответ придёт через latency — до тех пор она висит in-progress.
      def dispatch!(state, operation, outcome, now)
        state.dispatch!(operation, now)
        @pending.push(now + outcome.latency_sec, Settlement.new(state: state, operation: operation, outcome: outcome))
      end

      def select!(state, operation)
        state.select!(operation)
        @selected_total += 1
        @selected_amount_total += operation.amount
      end

      # Применить все ответы, время которых наступило.
      def settle_due(now)
        while (settlement = @pending.pop_due(now))
          settlement.state.settle!(settlement.operation, settlement.outcome)
        end
      end

      def settle_all
        while (settlement = @pending.pop)
          settlement.state.settle!(settlement.operation, settlement.outcome)
        end
      end

      def pending_settlements = @pending.size

      # Фактическая доля провайдера по числу заявок (в этой сессии), %.
      def count_share_pct(state)
        return 0.0 if @selected_total.zero?

        state.selected_count * 100.0 / @selected_total
      end

      # Фактическая доля по объёму за день: снимок (daily_approved_amount) + заявки сессии, %.
      def volume_share_pct(state)
        total = @external.sum(&:volume_in_flight)
        return 0.0 if total.zero?

        state.volume_in_flight * 100.0 / total
      end
    end
  end
end
