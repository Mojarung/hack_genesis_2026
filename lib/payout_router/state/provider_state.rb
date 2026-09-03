# frozen_string_literal: true

module PayoutRouter
  module State
    # Изменяемое состояние провайдера в ходе роутинга: оборот, in-progress, реквизиты,
    # моменты отправок (для лимита интенсивности) и счётчики исходов.
    class ProviderState
      RATE_WINDOW_SEC = 60

      attr_reader :provider, :daily_approved_amount, :in_progress_count, :in_progress_amount,
                  :available_requisites, :dispatch_count, :selected_count, :selected_amount,
                  :approved_count, :approved_amount, :rejected_count, :expired_count

      def initialize(provider)
        @provider = provider
        @daily_approved_amount = provider.daily_approved_amount || 0
        @in_progress_count = provider.in_progress_count || 0
        @in_progress_amount = provider.in_progress_amount || 0
        @available_requisites = provider.available_requisites || 0
        @dispatch_count = @selected_count = @selected_amount = 0
        @approved_count = @approved_amount = @rejected_count = @expired_count = 0
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

      # Провайдер ответил: освобождаем in-progress и реквизит, одобренное — в дневной оборот.
      def settle!(operation, outcome)
        @in_progress_count -= 1
        @in_progress_amount -= operation.amount
        @available_requisites += 1
        case outcome.result
        when "approved"
          @approved_count += 1
          @approved_amount += operation.amount
          @daily_approved_amount += operation.amount
        when "rejected" then @rejected_count += 1
        when "expired" then @expired_count += 1
        end
      end

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

      def ratio(used, limit)
        return 0.0 if limit.nil? || limit.zero?

        used.to_f / limit
      end
    end
  end
end
