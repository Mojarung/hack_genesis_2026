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

        # Доля точного оптимума, которую взял роутер. Знаменатель — free_optimum: наше распределение
        # заведомо допустимо в его задаче, поэтому это настоящая верхняя граница и величина не может
        # превысить 100%. quota_optimum на эту роль не годится — он решает более стеснённую задачу
        # (доли как жёсткое ограничение), а у роутера доли мягкая цель, и он законно его обходит.
        def score_vs_optimum = free_optimum.zero? ? 100.0 : ours * 100.0 / free_optimum

        # Разложение отставания. Отрицательный online_loss — роутер сознательно отступил от целевых
        # долей ради одобрений: он не обязан держать их жёстко, в отличие от quota_optimum.
        def share_loss = share_cost
        def online_loss = quota_optimum - ours

        def headline
          "Онлайн-роутинг взял #{score_vs_optimum.round(1)}% от точного оптимума этой очереди " \
            "(#{ours.round(2)} из #{free_optimum.round(2)} ожидаемых одобрений; оптимум посчитан " \
            "min-cost flow по всей очереди сразу). #{decomposition}"
        end

        # Отрицательный online_loss — роутер обошёл квотный оптимум: доли у него мягкая цель.
        def decomposition
          gap = (free_optimum - ours).round(2)
          if online_loss.negative?
            "Из отставания в #{gap} одобрения #{share_loss.round(2)} — цена жёстких целевых долей " \
              "(квотный оптимум #{quota_optimum.round(2)}), но роутер, держа доли мягко, отыграл " \
              "#{(-online_loss).round(2)} из них."
          else
            "Из отставания в #{gap} одобрения #{share_loss.round(2)} — цена обязательства держать " \
              "целевые доли, и #{online_loss.round(2)} — цена решений по одной заявке без знания следующих."
          end
        end

        def serialize
          {
            "headline" => headline,
            "score_vs_optimum_pct" => score_vs_optimum.round(2),
            "approvals_lost_to_share_targets" => share_loss.round(2),
            "approvals_lost_to_online_decisions" => online_loss.round(2),
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

      # Группа задачи — банк × набор допустимых провайдеров именно этой заявки: одна проба на банк
      # вычёркивала бы провайдера для всех заявок банка из-за одной крупной суммы, и граница
      # опускалась ниже фактического результата роутера.
      def call
        providers = @snapshot.external.map(&:name) + [@fallback].compact
        grouped = @operations.group_by { |operation| [operation.bank, eligible_set(operation, providers)] }
        groups = grouped.transform_values(&:size)
        build(groups, providers, gain_matrix(groups.keys, providers), quota_counts(@snapshot.external.map(&:name)))
      end

      private

      def build(banks, providers, gains, quotas)
        free = capacities(quotas.keys.to_h { |name| [name, @operations.size] })
        Result.new(operations: @operations.size, ours: ours,
                   all_to_self: banks.sum { |(bank, _eligible), count| count * self_probability(bank) },
                   free_optimum: solve(banks, providers, gains, free),
                   quota_optimum: solve(banks, providers, gains, capacities(quotas)),
                   worst: solve(banks, providers, gains, free, minimize: true),
                   quotas: quotas, self_budget: self_budget,
                   eligible_pairs: gains.count { |_pair, gain| !gain.nil? })
      end

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
      def gain_matrix(groups, providers)
        groups.product(providers).to_h do |group, provider|
          bank, eligible = group
          [[group, provider], eligible.include?(provider) ? @model.probability(provider, bank) : nil]
        end
      end

      def eligible_set(operation, providers)
        @pipeline ||= Constraints::Pipeline.new(@policy.hard_constraints & Constraints::Registry::STATIC)
        @ledger ||= State::Ledger.new(@snapshot)
        now = @snapshot.snapshot_at || Time.now
        providers.select do |provider|
          candidate = Routing::Candidate.new(state: @ledger.state(provider))
          @pipeline.evaluate(candidate, operation, now).eligible?
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
