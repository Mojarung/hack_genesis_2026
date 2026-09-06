# frozen_string_literal: true

module PayoutRouter
  module Analytics
    # Разобранные примеры решений прямо в отчёте.
    #
    # Просьба экспертов на чекпоинте 2 (05.09.2026): «добавьте несколько примеров — если в итоговом
    # отчёте видна логика отмены заявок и поиска новых решений, проверяющий быстрее найдёт
    # соответствующий код». Поэтому каждый пример — не только «что вышло», но и `source`: файл
    # и метод, где это решение принимается. Полный трейс всех заявок остаётся в routing_decisions.json,
    # здесь — четыре характерных случая, по одному на каждый механизм.
    class DecisionExamples
      NOTE = "разобранные примеры: кого выбрали, почему отсеяли остальных и что происходит при отказе. " \
             "У каждого примера source — где в коде принимается это решение, run — из какого прогона " \
             "взят пример. Полный трейс основного прогона — в routing_decisions.json; примеры с отказом " \
             "берутся из прогона с отказами (routing_cascade_demo.json), если в основном отказов не было"

      RUNS = {
        main: "основной прогон (routing_decisions.json)",
        cascade: "прогон с отказами, режим conversion (routing_cascade_demo.json)"
      }.freeze

      SOURCES = {
        scoring: "lib/payout_router/scoring/composite_scorer.rb → CompositeScorer#rank " \
                 "(нормировка по пулу кандидатов и взвешенная сумма целей)",
        hard: "lib/payout_router/constraints/pipeline.rb → Pipeline#evaluate " \
              "(правила из policy.hard_constraints, коды причин — routing/reasons.rb)",
        retry: "lib/payout_router/routing/router.rb → Router#try_ranked " \
               "(отправка, разбор исхода и переход к следующему кандидату по рангу)",
        fallback: "lib/payout_router/routing/router.rb → Router#fallback " \
                  "(пул внешних исчерпан — self-provider по policy.fallback_rules)"
      }.freeze

      def initialize(decisions:, cascade_decisions: [])
        @decisions = decisions
        @cascade = cascade_decisions
      end

      def call
        cases = { "note" => NOTE }
        add(cases, "choice_among_several", choice_among_several,
            "среди нескольких допустимых выбран лучший по сумме взвешенных целей", :scoring)
        add(cases, "single_eligible", single_eligible,
            "hard-правила оставили одного кандидата — скоринг уже ничего не решает", :hard)
        add(cases, "retry_after_failure", retry_after_failure,
            "провайдер отказал: заявка переотправлена следующему по рангу", :retry)
        add(cases, "fallback_to_self_provider", fallback_to_self_provider,
            "внешние кандидаты кончились — заявка ушла на self-provider", :fallback)
        cases
      end

      private

      def add(cases, key, decision, what, source)
        return if decision.nil?

        cases[key] = example(decision, what, source)
      end

      # Первая заявка, где у победителя был хотя бы один соперник, проигравший по скору.
      def choice_among_several
        @decisions.find do |decision|
          decision.attempts.any? { |attempt| attempt.reason == Routing::Reasons::LOWER_SCORE }
        end
      end

      def single_eligible
        @decisions.find { |decision| decision.reason == Routing::Reasons::ONLY_ELIGIBLE }
      end

      def retry_after_failure
        (@cascade + @decisions).find { |decision| decision.retries.positive? && !decision.fallback_used }
      end

      def fallback_to_self_provider
        (@cascade + @decisions).find(&:fallback_used)
      end

      def example(decision, what, source)
        {
          "what_it_shows" => what,
          "run" => RUNS.fetch(@cascade.any? { |item| item.equal?(decision) } ? :cascade : :main),
          "operation" => { "operation_id" => decision.operation_id, "amount" => decision.operation.amount,
                           "bank" => decision.operation.bank },
          "selected" => selected(decision),
          "skipped" => decision.attempts.reject(&:selected?).map { |attempt| skipped(attempt) },
          "outcome" => { "simulated_result" => decision.simulated_result, "retries" => decision.retries,
                         "fallback_used" => decision.fallback_used },
          "source" => SOURCES.fetch(source)
        }.compact
      end

      def selected(decision)
        attempt = decision.selected_attempt
        return nil if attempt.nil?

        { "provider" => attempt.provider, "reason" => attempt.reason, "why" => attempt.details,
          "score" => attempt.score&.round(4) }.compact
      end

      def skipped(attempt)
        { "provider" => attempt.provider, "reason" => attempt.reason, "why" => attempt.details,
          "dispatched" => attempt.dispatched? || nil, "simulated_result" => attempt.simulated_result }.compact
      end
    end
  end
end
