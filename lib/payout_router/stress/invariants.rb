# frozen_string_literal: true

module PayoutRouter
  module Stress
    # Свойства, которые обязаны держаться в любом сценарии, как бы ни давили на роутер.
    # Нарушение любого — это баг, а не «стратегия сработала плохо»: здесь строгие проверки,
    # а не пороги. Всё, что про качество распределения, живёт в метриках сценария.
    #
    # Проверки допустимости и интенсивности вынесены в Stress::Oracles: они считают всё заново
    # по решениям и снимку, потому что проверка, опирающаяся на бухгалтерию роутера,
    # подтверждала бы её самой этой бухгалтерией.
    module Invariants
      module_function

      # allow_unrouted — только для сценариев, где заявке физически некуда уйти
      # (нет fallback-провайдера). Во всех остальных заявка без маршрута — нарушение.
      #
      # enforce_daily_limit включается, когда политика взяла строгое правило daily_limit_reserved.
      # С формулой из ТЗ (`daily_limit`) перебор дневного лимита неизбежен по построению: оборот
      # растёт только по ответу провайдера, и пока он молчит, следующие заявки проходят проверку
      # по устаревшему числу. Это не баг роутера, а свойство формулы — поэтому там оно измеряется
      # метрикой, а не выдаётся за нарушение.
      def check(decisions:, operations:, ledger:, snapshot:, allow_unrouted: false, enforce_daily_limit: false)
        coverage(decisions, operations) +
          decisions.flat_map { |decision| trace(decision, allow_unrouted) } +
          Oracles.eligibility(decisions, snapshot) +
          Oracles.rate_window(decisions, snapshot) +
          ledger.states.values.flat_map { |state| capacity(state, snapshot, enforce_daily_limit) }
      end

      def coverage(decisions, operations)
        expected = operations.map(&:operation_id)
        actual = decisions.map(&:operation_id)
        missing = expected - actual
        extra = actual - expected
        duplicates = actual.tally.select { |_id, count| count > 1 }.keys

        [(violation("покрытие очереди", "нет решений для: #{missing.join(", ")}") unless missing.empty?),
         (violation("покрытие очереди", "лишние решения: #{extra.join(", ")}") unless extra.empty?),
         (violation("покрытие очереди", "решения дублируются: #{duplicates.join(", ")}") unless duplicates.empty?)]
          .compact
      end

      # Трейс одной заявки: ровно один selected, он же итоговый провайдер, и он не был
      # до этого отсеян hard-правилом в этой же заявке. Проверки дешёвые и по построению роутера
      # сработать не должны — они ловят рассогласование трейса и решения, а не ошибку в правилах.
      def trace(decision, allow_unrouted)
        [route_present(decision, allow_unrouted), selected_count(decision),
         selected_matches(decision), not_blocked(decision)].compact
      end

      def route_present(decision, allow_unrouted)
        return if decision.selected_provider || allow_unrouted

        violation("маршрут", "#{decision.operation_id}: selected_provider = null")
      end

      def selected_count(decision)
        expected = decision.selected_provider.nil? ? 0 : 1
        actual = decision.attempts.count(&:selected?)
        return if actual == expected

        violation("трейс", "#{decision.operation_id}: selected-попыток #{actual}, ожидалось #{expected}")
      end

      def selected_matches(decision)
        selected = decision.attempts.find(&:selected?)
        return if selected.nil? || selected.provider == decision.selected_provider

        violation("трейс", "#{decision.operation_id}: selected #{selected.provider} " \
                           "≠ selected_provider #{decision.selected_provider}")
      end

      def not_blocked(decision)
        chosen = decision.selected_provider
        return if chosen.nil? || decision.attempts.none? { |a| a.hard_skip? && a.provider == chosen }

        violation("hard-правила", "#{decision.operation_id}: #{chosen} и отсеян hard-правилом, и выбран")
      end

      # Ёмкость провайдера. Ключевая проверка — сохранение: после settle_all каждая отправка
      # обязана быть закрыта ответом, а всё занятое — возвращено. Исключение ровно одно:
      # таймауты при simulation.timeout: hold, которые по замыслу держат слот и реквизит вечно.
      # Без этой проверки утечка (не вернули слот при отказе) была бы невидима: она двигает
      # счётчики в «безопасную» сторону, и проверки «>= 0» и «пик <= лимита» остались бы довольны.
      #
      # К self-provider ёмкостные правила сознательно не применяются (Policy#fallback_rules):
      # он последняя линия и принимает всё, поэтому его счётчики законно уходят в минус —
      # насколько именно, показывает метрика перегрузки, а не нарушение.
      def capacity(state, snapshot, enforce_daily_limit)
        return [] unless state.provider.external?

        # Если счётчики перетирал внешний снимок, сходиться с исходным они и не обязаны —
        # источником истины стала вызывающая система. Остальные проверки остаются в силе.
        checks = state.counter_syncs.zero? ? conservation(state, snapshot.provider(state.name)) : []
        checks += non_negative(state) + limit_checks(state, enforce_daily_limit)
        checks.filter_map do |name, value, bound, operator|
          next if value.public_send(operator, bound)

          violation("ёмкость #{state.name}", "#{name} = #{value}, нарушает #{operator} #{bound}")
        end
      end

      def conservation(state, initial)
        held = state.held_timeout_count
        [["закрытых ответов", state.approved_count + state.rejected_count + state.expired_count,
          state.dispatch_count, :==],
         ["in_progress_count после прогона", state.in_progress_count, initial.in_progress_count + held, :==],
         ["in_progress_amount после прогона", state.in_progress_amount,
          initial.in_progress_amount + state.held_timeout_amount, :==],
         ["available_requisites после прогона", state.available_requisites,
          initial.available_requisites - held, :==]]
      end

      def non_negative(state)
        [["available_requisites", state.min_available_requisites, 0, :>=],
         ["in_progress_count", state.in_progress_count, 0, :>=],
         ["in_progress_amount", state.in_progress_amount, 0, :>=]]
      end

      def limit_checks(state, enforce_daily_limit)
        provider = state.provider
        checks = [["пик in_progress_count", state.peak_in_progress_count, provider.in_progress_count_limit, :<=],
                  ["пик in_progress_amount", state.peak_in_progress_amount, provider.in_progress_amount_limit, :<=]]
        if enforce_daily_limit
          checks << ["daily_approved_amount", state.daily_approved_amount, provider.daily_amount_limit, :<=]
        end
        checks.reject { |_name, _value, limit, _operator| limit.nil? }
      end

      def violation(rule, detail) = Violation.new(rule: rule, detail: detail)
    end
  end
end
