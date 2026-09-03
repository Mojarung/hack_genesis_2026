# frozen_string_literal: true

module PayoutRouter
  module Analytics
    # Сводные показатели прогона: распределение заявок и объёма, исходы, причины отсева,
    # достижимость целевых долей, загрузка лимитов. Всё считается за один проход по решениям.
    class RoutingStats
      attr_reader :decisions, :ledger, :snapshot, :total, :routed, :fallback_count, :retries

      def initialize(decisions:, ledger:, snapshot:)
        @decisions = decisions
        @ledger = ledger
        @snapshot = snapshot
        @total = decisions.size
        @routed = 0
        @fallback_count = 0
        @retries = 0
        @outcomes = Hash.new(0)
        @skip_reasons = Hash.new(0)
        @skip_by_provider = Hash.new { |hash, name| hash[name] = Hash.new(0) }
        @eligible = Hash.new(0)
        @blocked_banks = Hash.new { |hash, name| hash[name] = Hash.new(0) }
        @blocked_amounts = Hash.new { |hash, name| hash[name] = [] }
        @attempts_total = 0
        decisions.each { |decision| aggregate(decision) }
      end

      def unrouted = @total - @routed

      def distribution
        @distribution ||= reported_providers.to_h { |provider| [provider.name, distribution_for(provider)] }
      end

      def results
        {
          "approved" => @outcomes["approved"],
          "rejected" => @outcomes["rejected"],
          "expired" => @outcomes["expired"],
          "by_provider" => reported_providers.to_h { |provider| [provider.name, results_for(provider)] }
        }
      end

      def skip_reasons = @skip_reasons.sort_by { |_reason, count| -count }.to_h

      def skip_reasons_by_provider
        @skip_by_provider.transform_values { |reasons| reasons.sort_by { |_r, c| -c }.to_h }
      end

      def utilization
        @utilization ||= @ledger.states.to_h { |name, state| [name, utilization_for(state)] }
      end

      def attainability
        @attainability ||= @snapshot.external.to_h { |provider| [provider.name, attainability_for(provider)] }
      end

      def attempts_stats
        {
          "total" => @attempts_total,
          "avg_per_operation" => @total.zero? ? 0.0 : (@attempts_total.to_f / @total).round(2),
          "retries_after_failure" => @retries,
          "fallback_used" => @fallback_count,
          "unrouted" => unrouted
        }
      end

      # Самодиагностика скоринга: в скольких «конкурентных» заявках (два и более кандидата со скором)
      # каждая цель вообще различала кандидатов. Цель с нулём — на этих данных мёртвый вес.
      def goal_activity
        @goal_activity ||= begin
          contested = contested_breakdowns
          active = Hash.new(0)
          weights = {}
          contested.each do |scored|
            scored.first.breakdown.each do |goal, component|
              weights[goal] ||= component["weight"]
              active[goal] += 1 if discriminates?(scored, goal)
            end
          end
          { "contested_operations" => contested.size, "goals" => goal_rows(weights, active, contested.size) }
        end
      end

      private

      def reported_providers
        used = @decisions.filter_map(&:selected_provider).to_set
        @snapshot.providers.select { |provider| provider.external? || used.include?(provider.name) }
      end

      def aggregate(decision)
        @routed += 1 if decision.routed?
        @fallback_count += 1 if decision.fallback_used
        @retries += decision.retries
        @outcomes[decision.simulated_result] += 1
        @attempts_total += decision.attempts.size
        decision.attempts.each { |attempt| aggregate_attempt(decision, attempt) }
      end

      def aggregate_attempt(decision, attempt)
        if attempt.hard_skip?
          @skip_reasons[attempt.reason] += 1
          @skip_by_provider[attempt.provider][attempt.reason] += 1
          track_block(decision, attempt)
        else
          @eligible[attempt.provider] += 1
          @skip_reasons[attempt.reason] += 1 if Routing::Reasons::FAILURES.include?(attempt.reason)
        end
      end

      def track_block(decision, attempt)
        case attempt.reason
        when Routing::Reasons::BANK_NOT_IN_LIST, Routing::Reasons::BANK_EXCLUDED
          @blocked_banks[attempt.provider][decision.operation.bank] += 1
        when Routing::Reasons::AMOUNT_EXCEEDS_LIMIT, Routing::Reasons::AMOUNT_BELOW_MINIMUM
          @blocked_amounts[attempt.provider] << decision.operation.amount
        end
      end

      def distribution_for(provider)
        state = @ledger.state(provider.name)
        share = share_pct(state.selected_count, @routed)
        volume_share = share_pct(state.selected_amount, @ledger.selected_amount_total)
        target = provider.fallback? ? 0 : provider.traffic_percentage
        volume_target = provider.fallback? ? 0 : provider.volume_target_pct
        {
          "count" => state.selected_count,
          "share_pct" => share.round(1),
          "target_pct" => target,
          "deviation_pp" => (share - target).round(1),
          "volume" => state.selected_amount,
          "volume_share_pct" => volume_share.round(1),
          "target_volume_pct" => volume_target,
          "volume_deviation_pp" => (volume_share - volume_target).round(1)
        }
      end

      def results_for(provider)
        state = @ledger.state(provider.name)
        {
          "dispatched" => state.dispatch_count,
          "approved" => state.approved_count,
          "rejected" => state.rejected_count,
          "expired" => state.expired_count,
          "conversion_simulated" => simulated_conversion(state),
          "conversion_24h" => provider.conversion_24h,
          "circuit_trips" => state.circuit_trips
        }
      end

      def utilization_for(state)
        provider = state.provider
        limit = provider.daily_amount_limit
        {
          "used" => state.daily_approved_amount,
          "limit" => limit,
          "utilization_pct" => limit.nil? || limit.zero? ? nil : (state.daily_approved_amount * 100.0 / limit).round(1),
          "remaining" => limit && (limit - state.daily_approved_amount),
          "in_progress_count" => state.in_progress_count,
          "in_progress_count_limit" => provider.in_progress_count_limit,
          "in_progress_amount" => state.in_progress_amount,
          "in_progress_amount_limit" => provider.in_progress_amount_limit,
          "available_requisites" => state.available_requisites
        }
      end

      def attainability_for(provider)
        eligible = @eligible[provider.name]
        amounts = @blocked_amounts[provider.name]
        {
          "considered" => @total,
          "eligible" => eligible,
          "eligible_pct" => share_pct(eligible, @total).round(1),
          "max_attainable_share_pct" => share_pct(eligible, @total).round(1),
          "blocked_by" => @skip_by_provider[provider.name].sort_by { |_r, c| -c }.to_h,
          "blocked_banks" => @blocked_banks[provider.name].sort_by { |_b, c| -c }.to_h,
          "blocked_amounts" => if amounts.empty?
                                 nil
                               else
                                 { "min" => amounts.min, "max" => amounts.max,
                                   "count" => amounts.size }
                               end
        }
      end

      def share_pct(part, whole) = whole.zero? ? 0.0 : part * 100.0 / whole

      # Попытки со скором по каждой заявке, где кандидатов было двое и больше.
      def contested_breakdowns
        @decisions.map { |decision| decision.attempts.select(&:breakdown) }.select { |scored| scored.size > 1 }
      end

      def goal_rows(weights, active, contested)
        weights.to_h do |goal, weight|
          [goal, { "weight" => weight, "discriminating_operations" => active[goal],
                   "share_pct" => share_pct(active[goal], contested).round(1) }]
        end
      end

      # Цель различала кандидатов заявки: её оценки у них не совпадают.
      def discriminates?(scored, goal)
        values = scored.filter_map { |attempt| attempt.breakdown.dig(goal, "score") }
        values.size > 1 && (values.max - values.min) > 1e-9
      end

      def simulated_conversion(state)
        return nil if state.dispatch_count.zero?

        (state.approved_count.to_f / state.dispatch_count).round(3)
      end
    end
  end
end
