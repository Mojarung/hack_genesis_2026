# frozen_string_literal: true

module PayoutRouter
  module State
    # Изменяемое состояние провайдера в ходе роутинга: оборот, in-progress, реквизиты,
    # моменты отправок (для лимита интенсивности), счётчики исходов и предохранитель.
    class ProviderState
      RATE_WINDOW_SEC = 60

      attr_reader :provider, :breaker, :daily_approved_amount, :in_progress_count, :in_progress_amount,
                  :available_requisites, :dispatch_count, :selected_count, :selected_amount,
                  :approved_count, :approved_amount, :rejected_count, :expired_count,
                  :consecutive_failures, :circuit_open_until, :circuit_trips

      def initialize(provider, breaker: nil)
        @provider = provider
        @breaker = breaker
        @daily_approved_amount = provider.daily_approved_amount || 0
        @in_progress_count = provider.in_progress_count || 0
        @in_progress_amount = provider.in_progress_amount || 0
        @available_requisites = provider.available_requisites || 0
        @dispatch_count = @selected_count = @selected_amount = 0
        @approved_count = @approved_amount = @rejected_count = @expired_count = 0
        @consecutive_failures = @circuit_trips = 0
        @circuit_open_until = nil
        @request_times = []
      end

      def name = provider.name

      # Заявка отправлена провайдеру: занимает реквизит и место в in-progress до ответа.
      def dispatch!(operation, now)
        @in_progress_count += 1
        @in_progress_amount += operation.amount
        @available_requisites -= 1
        @dispatch_count += 1
        @request_times << now
      end

      # Заявка закреплена за провайдером как итоговый выбор — учитывается в долях трафика.
      def select!(operation)
        @selected_count += 1
        @selected_amount += operation.amount
      end

      # Провайдер ответил (в момент at): освобождаем in-progress и реквизит,
      # одобренное — в дневной оборот, серия отказов — в предохранитель.
      def settle!(operation, outcome, at: nil)
        @in_progress_count -= 1
        @in_progress_amount -= operation.amount
        @available_requisites += 1
        case outcome.result
        when "approved" then record_approval(operation)
        when "rejected"
          @rejected_count += 1
          record_failure(at)
        when "expired"
          @expired_count += 1
          record_failure(at)
        end
      end

      # Предохранитель разомкнут: провайдер в карантине до circuit_open_until.
      def circuit_open?(now) = !@circuit_open_until.nil? && now < @circuit_open_until

      # Отправок за последнюю минуту. Времена монотонны (очередь идёт по created_at),
      # поэтому устаревшие просто срезаем с начала.
      def requests_within(now, window = RATE_WINDOW_SEC)
        threshold = now - window
        @request_times.shift while !@request_times.empty? && @request_times.first <= threshold
        @request_times.size
      end

      # Дневной объём с учётом заявок, которые ещё в обработке.
      def volume_in_flight = @daily_approved_amount + @in_progress_amount

      # Загрузка по каждому лимиту (0..1+); без лимита — 0.
      def utilization
        {
          daily: ratio(@daily_approved_amount, provider.daily_amount_limit),
          in_progress_count: ratio(@in_progress_count, provider.in_progress_count_limit),
          in_progress_amount: ratio(@in_progress_amount, provider.in_progress_amount_limit)
        }
      end

      def max_utilization = utilization.values.max

      private

      def record_approval(operation)
        @approved_count += 1
        @approved_amount += operation.amount
        @daily_approved_amount += operation.amount
        @consecutive_failures = 0
      end

      def record_failure(at)
        @consecutive_failures += 1
        return if at.nil? || @breaker.nil? || !@breaker.enabled? || @consecutive_failures < @breaker.failures

        @circuit_open_until = at + @breaker.cooldown_sec
        @circuit_trips += 1
        @consecutive_failures = 0
      end

      def ratio(used, limit)
        return 0.0 if limit.nil? || limit.zero?

        used.to_f / limit
      end
    end
  end
end
