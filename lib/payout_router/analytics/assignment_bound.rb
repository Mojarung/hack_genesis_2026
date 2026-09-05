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
    # Эталон распределяет по внешним провайдерам, self-provider получает только то, что не берёт
    # никто, — как написано в ТЗ. Отдельным числом печатаем «вся очередь на себя»: у spacepayments
    # нет истории, заявленная конверсия 0.95 (против откалиброванных 0.62–0.80 у внешних), нет
    # лимитов и лучшая маржа, поэтому любая цель «максимум одобрений» без обязательств скатывается
    # именно туда; из обычного пула его держит только правило traffic_enabled (traffic_percentage 0).
    #
    # Четыре числа отвечают, где мы находимся:
    #   all_to_self   — вырожденный максимум, к которому тянет чистая конверсия;
    #   free_optimum  — лучшее распределение по внешним, доли не ограничены;
    #   quota_optimum — лучшее при условии, что никто не берёт больше своей целевой доли;
    #   worst         — худшее допустимое при тех же квотах: нижняя точка отсчёта для capture.
    class AssignmentBound
      Result = Data.define(:operations, :ours, :all_to_self, :free_optimum, :quota_optimum, :worst,
                           :quotas, :self_ops_ours, :self_ops_optimum, :eligible_pairs) do
        def gap_to_free = free_optimum.zero? ? 0.0 : (free_optimum - ours) * 100.0 / free_optimum
        def gap_to_quota = quota_optimum.zero? ? 0.0 : (quota_optimum - ours) * 100.0 / quota_optimum
        def share_cost = free_optimum - quota_optimum

        # Какую долю достижимого при соблюдении долей мы забираем: 1 — оптимум, 0 — худшее допустимое.
        def capture
          span = quota_optimum - worst
          span.abs < 1e-9 ? 1.0 : ((ours - worst) / span).clamp(0.0, 1.0)
        end

        def serialize
          {
            "operations" => operations, "expected_approvals_ours" => ours.round(2),
            "baseline_all_to_self_provider" => all_to_self.round(2),
            "optimum_free_shares" => free_optimum.round(2),
            "optimum_with_target_shares" => quota_optimum.round(2),
            "worst_with_target_shares" => worst.round(2),
            "gap_to_free_pct" => gap_to_free.round(2), "gap_to_quota_pct" => gap_to_quota.round(2),
            "share_compliance_cost_approvals" => share_cost.round(2),
            "capture_of_attainable" => capture.round(3),
            "self_provider_operations_ours" => self_ops_ours,
            "self_provider_operations_optimum" => self_ops_optimum,
            "quotas" => quotas, "eligible_pairs" => eligible_pairs,
            "method" => "transportation problem bank × provider solved exactly as min-cost flow; " \
                        "static hard rules only, no capacity, requisite or rate limits — the reference " \
                        "assignment knows the whole queue in advance"
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
        external = @snapshot.external.map(&:name)
        gains = gain_matrix(banks.keys, external)
        quotas = quota_counts(external)
        free = solve(banks, external, gains, external.to_h { |name| [name, @operations.size] })
        quota = solve(banks, external, gains, quotas)
        build(banks, gains, quotas, free, quota)
      end

      private

      def build(banks, gains, quotas, free, quota)
        Result.new(operations: @operations.size, ours: ours,
                   all_to_self: banks.sum { |bank, count| count * self_probability(bank) },
                   free_optimum: free[:approvals], quota_optimum: quota[:approvals],
                   worst: solve(banks, quotas.keys, gains, quotas, minimize: true)[:approvals],
                   quotas: quotas, self_ops_ours: self_ops_ours, self_ops_optimum: quota[:leftovers],
                   eligible_pairs: gains.count { |_pair, gain| !gain.nil? })
      end

      def self_probability(bank) = @fallback ? @model.probability(@fallback, bank) : 0.0

      def self_ops_ours = @decisions.count { |decision| decision.selected_provider == @fallback }

      def ours
        @decisions.select(&:routed?).sum do |decision|
          @model.probability(decision.selected_provider, decision.operation.bank)
        end
      end

      # Вероятность одобрения пары «банк × внешний провайдер», nil — пара недопустима.
      # Допустимость по правилам, не зависящим от загрузки: остальное требует состояния,
      # которого у статической задачи нет. Дополнительные правила только сузили бы пул.
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

      # Заявки, которых не берёт ни один внешний (или которым не хватило квоты), уходят
      # на self-provider — ровно как в роутере, поэтому их вклад добавляем по его вероятности.
      def solve(banks, providers, gains, capacities, minimize: false)
        flow = MinCostFlow.new(banks.size + providers.size + 2)
        source = banks.size + providers.size
        sink = source + 1
        supply = banks.each_value.map.with_index { |count, index| flow.add(source, index, count, 0.0) }
        providers.each_with_index { |name, index| flow.add(banks.size + index, sink, capacities.fetch(name, 0), 0.0) }
        connect(flow, banks, providers, gains, minimize: minimize)
        cost = flow.run(source, sink)
        placed = minimize ? cost : -cost
        { approvals: placed + tail(banks, supply), leftovers: supply.sum(&:capacity) }
      end

      def connect(flow, banks, providers, gains, minimize:)
        banks.each_key.with_index do |bank, row|
          providers.each_with_index do |name, column|
            gain = gains[[bank, name]]
            flow.add(row, banks.size + column, @operations.size, minimize ? gain : -gain) unless gain.nil?
          end
        end
      end

      def tail(banks, supply)
        banks.each_key.with_index.sum { |bank, index| supply[index].capacity * self_probability(bank) }
      end
    end
  end
end
