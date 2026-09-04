# frozen_string_literal: true

module PayoutRouter
  module Stress
    # Проверки, которые считают всё заново по решениям и снимку, не заглядывая в бухгалтерию
    # роутера. Это принципиально: проверка, пользующаяся тем же счётчиком, который она проверяет,
    # подтверждает сама себя и молчит на ошибке в правиле. Мутационный прогон показал это прямо —
    # сдвиг границы limit_amount_max на 1 ₽ и поломка окна интенсивности проходили незамеченными,
    # пока эти две проверки читали `attempts` и `peak_requests_per_minute` вместо исходных данных.
    module Oracles
      module_function

      # Выбранный провайдер обязан подходить заявке по правилам, которые не зависят от состояния
      # и которых не меняет внешний снимок: диапазон чека и фильтр банков. Именно они отвечают
      # за «выплата ушла провайдеру, который её не принимает».
      def eligibility(decisions, snapshot)
        providers = snapshot.providers.to_h { |provider| [provider.name, provider] }
        decisions.filter_map do |decision|
          provider = providers[decision.selected_provider]
          next if provider.nil?

          problem = mismatch(provider, decision.operation)
          next if problem.nil?

          Violation.new(rule: "допустимость", detail: "#{decision.operation_id}: #{provider.name} — #{problem}")
        end
      end

      def mismatch(provider, operation)
        min = provider.limit_amount_min
        max = provider.limit_amount_max
        return "сумма #{operation.amount} < limit_amount_min #{min}" if min && operation.amount < min
        return "сумма #{operation.amount} > limit_amount_max #{max}" if max && operation.amount > max
        return "банк #{operation.bank} не проходит banks/exclude_banks" unless provider.bank_allowed?(operation.bank)

        nil
      end

      # Пик отправок за скользящую минуту, посчитанный по временам заявок из решений.
      def rate_window(decisions, snapshot)
        stamps = dispatch_times(decisions)
        snapshot.external.filter_map do |provider|
          limit = provider.requests_per_minute_limit
          next if limit.nil?

          peak = sliding_peak(stamps[provider.name])
          next if peak <= limit

          Violation.new(rule: "интенсивность #{provider.name}",
                        detail: "пик #{peak} отправок за минуту > лимита #{limit}")
        end
      end

      def dispatch_times(decisions)
        stamps = Hash.new { |hash, name| hash[name] = [] }
        decisions.each do |decision|
          decision.attempts.select(&:dispatched?).each do |attempt|
            stamps[attempt.provider] << decision.operation.created_at
          end
        end
        stamps
      end

      # Два указателя по отсортированным временам: окно (now − 60, now], как в правиле.
      def sliding_peak(times)
        sorted = times.sort
        window = State::ProviderState::RATE_WINDOW_SEC
        left = 0
        peak = 0
        sorted.each_with_index do |now, right|
          left += 1 while sorted[left] <= now - window
          peak = [peak, right - left + 1].max
        end
        peak
      end
    end
  end
end
