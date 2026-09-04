# frozen_string_literal: true

module PayoutRouter
  module Constraints
    # Строгий дневной максимум: под заявки, которые уже отправлены и ждут ответа, лимит резервируется.
    #
    # ТЗ задаёт правило как «daily_approved_amount + amount <= daily_amount_limit», и `daily_limit`
    # считает ровно так. Но daily_approved_amount растёт только когда провайдер ответил, а пока он
    # молчит, следующие заявки проходят проверку по устаревшему числу — и на длинной очереди
    # дневной лимит превышается (стресс-сценарий flood показывает перебор на несколько процентов).
    #
    # Здесь считаем по volume_in_flight = оборот + всё, что в обработке. Это то самое резервирование
    # лимита, о котором говорили эксперты: провайдер занят суммой с момента отправки, а не с момента
    # ответа. Правило строже буквы ТЗ, поэтому включается политикой отдельно — см. config/policies/strict_limits.yml.
    class DailyLimitReserved < Base
      def call(candidate, operation, _now)
        limit = candidate.provider.daily_amount_limit
        return pass if limit.nil?

        reserved = candidate.state.volume_in_flight
        return pass if reserved + operation.amount <= limit

        violation(Routing::Reasons::DAILY_LIMIT_EXCEEDED,
                  "daily #{reserved} (оборот + in-progress) + #{operation.amount} > daily_amount_limit #{limit}")
      end
    end
  end
end
