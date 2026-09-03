# frozen_string_literal: true

module PayoutRouter
  module Routing
    # Роутинг одной заявки:
    #   1. hard-constraints отсеивают недопустимых (каждому — причина в attempts);
    #   2. допустимые ранжируются взвешенным скорингом по soft-goals;
    #   3. отправляем лучшему; отказ/таймаут → следующий по рангу;
    #   4. внешних не осталось → fallback на self-provider; нет и его → заявка не маршрутизирована.
    # После каждой отправки леджер обновляет загрузку, оборот и счётчики интенсивности.
    class Router
      def initialize(snapshot:, policy:, ledger:, simulator:, history: nil)
        @ledger = ledger
        @simulator = simulator
        @constraints = Constraints::Pipeline.new(policy.hard_constraints)
        @scorer = Scoring.build(policy: policy, snapshot: snapshot, history: history)
        @external = ledger.external_states
                          .sort_by { |state| [state.provider.priority, state.name] }
                          .map { |state| Candidate.new(provider: state.provider, state: state) }
                          .freeze
        fallback = ledger.fallback_state
        @fallback = fallback && Candidate.new(provider: fallback.provider, state: fallback)
      end

      def route(operation)
        now = operation.created_at
        @ledger.settle_due(now)
        attempts = []
        eligible = filter(operation, now, attempts)
        return fallback(operation, attempts, now, cause: "no eligible external provider") if eligible.empty?

        ranked = @scorer.rank(eligible, Scoring::Context.new(operation: operation, ledger: @ledger, now: now))
        try_ranked(ranked, operation, now, attempts) ||
          fallback(operation, attempts, now, cause: "all #{ranked.size} eligible providers failed")
      end

      private

      def filter(operation, now, attempts)
        eligible = []
        @external.each do |candidate|
          evaluation = @constraints.evaluate(candidate, operation, now)
          if evaluation.eligible?
            eligible << candidate
          else
            attempts << Attempt.skipped(candidate.name, evaluation.reason, evaluation.details,
                                        violations: evaluation.reasons)
          end
        end
        eligible
      end

      # Идём по кандидатам в порядке скора; первый одобривший становится решением.
      def try_ranked(ranked, operation, now, attempts)
        ranked.each_with_index do |score, index|
          outcome = dispatch(score.candidate, operation, now)
          unless outcome.approved?
            attempts << failed_attempt(score, outcome)
            next
          end

          selected = selected_attempt(score, outcome, index, ranked.size)
          attempts << selected
          ranked.drop(index + 1).each { |loser| attempts << outscored_attempt(loser, score) }
          return decide(operation, score.candidate, attempts, selected, retries: index, fallback_used: false)
        end
        nil
      end

      def dispatch(candidate, operation, now)
        outcome = @simulator.call(candidate, operation)
        @ledger.dispatch!(candidate.state, operation, outcome, now)
        outcome
      end

      def fallback(operation, attempts, now, cause:)
        if @fallback
          evaluation = @constraints.evaluate(@fallback, operation, now)
          return dispatch_fallback(operation, attempts, now, cause) if evaluation.eligible?

          attempts << Attempt.skipped(@fallback.name, evaluation.reason, evaluation.details,
                                      violations: evaluation.reasons)
        end
        unrouted(operation, attempts)
      end

      def dispatch_fallback(operation, attempts, now, cause)
        retries = attempts.count(&:dispatched?)
        outcome = dispatch(@fallback, operation, now)
        selected = Attempt.selected(@fallback.name, Reasons::FALLBACK_SELF_PROVIDER, "#{cause}: #{summarize(attempts)}",
                                    simulated_result: outcome.result, latency_sec: outcome.latency_sec)
        attempts << selected
        decide(operation, @fallback, attempts, selected, retries: retries, fallback_used: true)
      end

      def selected_attempt(score, outcome, index, pool_size)
        reason = if index.positive? then Reasons::FALLBACK_AFTER_FAILURE
                 elsif pool_size == 1 then Reasons::ONLY_ELIGIBLE
                 else Reasons::BEST_SCORE
                 end
        details = index.positive? ? "retry ##{index} after failure; #{score.summary}" : score.summary
        Attempt.selected(score.name, reason, details,
                         score: score.total, breakdown: score.breakdown,
                         simulated_result: outcome.result, latency_sec: outcome.latency_sec)
      end

      def failed_attempt(score, outcome)
        Attempt.skipped(score.name, outcome.failure_reason,
                        "dispatched, simulated result: #{outcome.result} after #{outcome.latency_sec}s " \
                        "(#{score.summary})",
                        score: score.total, breakdown: score.breakdown,
                        simulated_result: outcome.result, latency_sec: outcome.latency_sec)
      end

      def outscored_attempt(loser, winner)
        Attempt.skipped(loser.name, Reasons::LOWER_SCORE,
                        "score #{loser.total.round(4)} < #{winner.total.round(4)} (#{winner.name})",
                        score: loser.total, breakdown: loser.breakdown)
      end

      def decide(operation, candidate, attempts, selected, retries:, fallback_used:)
        @ledger.select!(candidate.state, operation)
        Decision.new(operation: operation, selected_provider: candidate.name, reason: selected.reason,
                     attempts: attempts, simulated_result: selected.simulated_result,
                     latency_sec: selected.latency_sec, retries: retries, fallback_used: fallback_used)
      end

      # Никто не смог принять заявку: провайдера нет, результат — отказ, трейс объясняет почему.
      def unrouted(operation, attempts)
        Decision.new(operation: operation, selected_provider: nil, reason: Reasons::NO_ELIGIBLE_PROVIDER,
                     attempts: attempts, simulated_result: Simulation::Outcome::REJECTED, latency_sec: 0,
                     retries: attempts.count(&:dispatched?), fallback_used: false)
      end

      def summarize(attempts) = attempts.map { |attempt| "#{attempt.provider}: #{attempt.reason}" }.join("; ")
    end
  end
end
