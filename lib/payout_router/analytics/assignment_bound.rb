# frozen_string_literal: true

module PayoutRouter
  module Analytics
    # Насколько хорош наш роутинг по сравнению с наилучшим возможным распределением этой очереди.
    #
    # Роутер работает онлайн: решает по одной заявке, не зная следующих. Эталон считается иначе —
    # вся очередь распределяется целиком как транспортная задача «банк × провайдер» и решается
    # точно (min-cost flow). У эталона две форы: он знает будущее и не считает ёмкости по деньгам,
    # реквизитам и интенсивности. Поэтому он и полезен: если наш роутинг отстаёт на проценты,
    # крутить веса дальше бессмысленно — предел не в стратегии, а в данных.
    #
    # Ключевая деталь модели: self-provider доступен эталону ровно в том же объёме, в каком его
    # использовал наш роутер. Без этого ограничения задача вырождается — у spacepayments нет истории,
    # заявленная конверсия 0.95 против откалиброванных 0.62–0.80 у внешних, нет лимитов и лучшая
    # маржа, так что «отправить всё себе» побеждает любую стратегию. Из обычного пула его держит
    # только hard-правило traffic_enabled (traffic_percentage = 0), а здесь — равная с нами квота.
    # Тогда наше распределение заведомо допустимо в задаче эталона, и free_optimum — честная
    # верхняя граница, а не другое число.
    #
    # Четыре величины отвечают, где мы находимся:
    #   ours          — ожидаемые одобрения нашего роутинга;
    #   free_optimum  — лучшее назначение при тех же правилах допуска и той же квоте self-provider;
    #   quota_optimum — то же плюс условие «никто из внешних не берёт больше своей целевой доли»;
    #   worst         — худшее допустимое назначение: нижняя точка отсчёта.
    class AssignmentBound
      Result = Data.define(:operations, :ours, :all_to_self, :free_optimum, :quota_optimum, :worst,
                           :quotas, :self_budget, :eligible_pairs) do
        def gap_to_free = free_optimum.zero? ? 0.0 : (free_optimum - ours) * 100.0 / free_optimum
        def gap_to_quota = quota_optimum.zero? ? 0.0 : (quota_optimum - ours) * 100.0 / quota_optimum

        # Во сколько одобрений обходится требование не превышать целевые доли.
        def share_cost = free_optimum - quota_optimum

        # Какую долю разброса допустимых назначений мы забираем: 1 — оптимум, 0 — худшее.
        def capture
          span = free_optimum - worst
          span.abs < 1e-9 ? 1.0 : ((ours - worst) / span).clamp(0.0, 1.0)
        end

        def serialize
          {
            "operations" => operations, "expected_approvals_ours" => ours.round(2),
            "optimum_same_self_provider_budget" => free_optimum.round(2),
            "optimum_with_target_shares" => quota_optimum.round(2),
            "worst_feasible" => worst.round(2),
            "baseline_all_to_self_provider" => all_to_self.round(2),
            "gap_to_optimum_pct" => gap_to_free.round(2),
            "gap_to_quota_pct" => gap_to_quota.round(2),
            "share_compliance_cost_approvals" => share_cost.round(2),
            "capture_of_attainable" => capture.round(3),
            "self_provider_budget" => self_budget, "quotas" => quotas, "eligible_pairs" => eligible_pairs,
            "method" => "transportation problem bank × provider solved exactly as min-cost flow; " \
                        "static hard rules only, no capacity, requisite or rate limits; the reference " \
                        "knows the whole queue in advance and may use the self-provider at most as " \
                        "many times as our router did"
          }
        end
      end

      def initialize(snapshot:, policy:, history:, operations:, decisions:)
        @snapshot = snapshot
        @policy = policy
        @operations = operations
        @decisions = decisions
        @model = ApprovalModel.new(history: history, snapshot: snapshot)
        @fallback = snapshot.fallback&.name
      end

      def call
        banks = @operations.group_by(&:bank).transform_values(&:size)
        providers = @snapshot.external.map(&:name) + [@fallback].compact
        gains = gain_matrix(banks.keys, providers)
        quotas = quota_counts(@snapshot.external.map(&:name))
        free = capacities(quotas.keys.to_h { |name| [name, @operations.size] })
        Result.new(operations: @operations.size, ours: ours,
                   all_to_self: banks.sum { |bank, count| count * self_probability(bank) },
                   free_optimum: solve(banks, providers, gains, free),
                   quota_optimum: solve(banks, providers, gains, capacities(quotas)),
                   worst: solve(banks, providers, gains, free, minimize: true),
                   quotas: quotas, self_budget: self_budget,
                   eligible_pairs: gains.count { |_pair, gain| !gain.nil? })
      end

      private

      # Эталону разрешено ровно столько self-provider, сколько использовал наш роутер: иначе
      # «отправить всё себе» выигрывает у любой стратегии и сравнивать становится нечего.
      def capacities(external) = @fallback ? external.merge(@fallback => self_budget) : external

      def self_budget = @self_budget ||= @decisions.count { |item| item.selected_provider == @fallback }

      def self_probability(bank) = @fallback ? @model.probability(@fallback, bank) : 0.0

      def ours
        @decisions.select(&:routed?).sum do |decision|
          @model.probability(decision.selected_provider, decision.operation.bank)
        end
      end

      # Вероятность одобрения пары «банк × провайдер», nil — пара недопустима. Допустимость
      # по правилам, не зависящим от загрузки: остальное требует состояния, которого у статической
      # задачи нет. Дополнительные правила только сузили бы пул, то есть опустили бы границу.
      def gain_matrix(banks, providers)
        pipeline = Constraints::Pipeline.new(@policy.hard_constraints & Constraints::Registry::STATIC)
        ledger = State::Ledger.new(@snapshot)
        now = @snapshot.snapshot_at || Time.now
        banks.product(providers).to_h do |bank, provider|
          probe = @operations.find { |operation| operation.bank == bank }
          candidate = Routing::Candidate.new(state: ledger.state(provider))
          allowed = pipeline.evaluate(candidate, probe, now).eligible?
          [[bank, provider], allowed ? @model.probability(provider, bank) : nil]
        end
      end

      def quota_counts(providers)
        total = @operations.size
        raw = providers.to_h { |name| [name, @snapshot.provider(name).traffic_percentage.to_f * total / 100.0] }
        counts = raw.transform_values(&:floor)
        remainder = total - counts.values.sum
        largest = raw.sort_by { |name, value| [-(value - counts[name]), name] }.first([remainder, 0].max)
        largest.each { |pair| counts[pair.first] += 1 }
        counts
      end

      # Заявку, которой не нашлось места (никто не допустим или всё выбрано квотами), эталон
      # просто не отправляет — как и роутер, она даёт ноль ожидаемых одобрений.
      def solve(banks, providers, gains, capacities, minimize: false)
        flow = MinCostFlow.new(banks.size + providers.size + 2)
        source = banks.size + providers.size
        sink = source + 1
        banks.each_value.with_index { |count, index| flow.add(source, index, count, 0.0) }
        providers.each_with_index { |name, index| flow.add(banks.size + index, sink, capacities.fetch(name, 0), 0.0) }
        connect(flow, banks, providers, gains, minimize: minimize)
        cost = flow.run(source, sink)
        minimize ? cost : -cost
      end

      def connect(flow, banks, providers, gains, minimize:)
        banks.each_key.with_index do |bank, row|
          providers.each_with_index do |name, column|
            gain = gains[[bank, name]]
            flow.add(row, banks.size + column, @operations.size, minimize ? gain : -gain) unless gain.nil?
          end
        end
      end
    end
  end
end
