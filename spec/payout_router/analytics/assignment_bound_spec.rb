# frozen_string_literal: true

RSpec.describe "эталонное распределение очереди" do
  let(:history) do
    PayoutRouter::Analytics::HistoryStats.new(
      PayoutRouter::Inputs::HistoryLoader.load(data_path("operations_history.csv"))
    )
  end
  let(:policy) { PayoutRouter::Inputs::PolicyLoader.load(config_path("policy.yml")) }
  let(:snapshot) { policy.apply(PayoutRouter::Inputs::ProvidersLoader.load(data_path("providers.json"))) }
  let(:operations) do
    PayoutRouter::Inputs::QueueLoader.new(PayoutRouter::Inputs::JSONFile.read(data_path("operations_queue_10.json")),
                                          source: "queue", default_time: snapshot.snapshot_at).call
  end
  let(:result) do
    PayoutRouter::Routing::BatchRouter.new(snapshot: snapshot, policy: policy,
                                           simulator: PayoutRouter::Simulation::Optimistic.new,
                                           history: history).call(operations).decisions
  end
  let(:decisions) { result }

  describe PayoutRouter::Analytics::AssignmentBound do
    subject(:bound) do
      described_class.new(snapshot: snapshot, policy: policy, history: history,
                          operations: operations, decisions: decisions).call
    end

    it "оптимум — верхняя граница: наш роутинг его не превосходит, а квоты его только опускают" do
      expect(bound.free_optimum).to be >= bound.ours - 1e-9
      expect(bound.free_optimum).to be >= bound.quota_optimum - 1e-9
      expect(bound.free_optimum).to be >= bound.worst - 1e-9
      expect(bound.operations).to eq(operations.size)
    end

    it "квоты распределяют ровно всю очередь по целевым долям" do
      expect(bound.quotas.values.sum).to eq(operations.size)
      expect(bound.quotas.keys).to match_array(snapshot.external.map(&:name))
    end

    it "эталону разрешено столько self-provider, сколько использовал роутер" do
      used = result.count { |decision| decision.selected_provider == snapshot.fallback.name }

      expect(bound.self_budget).to eq(used)
    end

    it "наш роутинг лежит между худшим допустимым назначением и оптимумом" do
      expect(bound.ours).to be_between(bound.worst - 1e-9, bound.free_optimum + 1e-9)
      expect(bound.capture).to be_between(0.0, 1.0)
    end

    it "сериализуется с разрывами и ценой соблюдения долей" do
      serialized = bound.serialize

      expect(serialized).to include("expected_approvals_ours", "optimum_same_self_provider_budget",
                                    "optimum_with_target_shares", "gap_to_optimum_pct",
                                    "share_compliance_cost_approvals")
      expect(serialized["share_compliance_cost_approvals"]).to be >= 0
    end

    it "главная цифра считается от настоящей верхней границы и потому не превышает 100%" do
      expect(bound.score_vs_optimum).to be_within(1e-6).of(bound.ours * 100.0 / bound.free_optimum)
      expect(bound.score_vs_optimum).to be <= 100.0
      expect(bound.serialize["score_vs_optimum_pct"]).to eq(bound.score_vs_optimum.round(2))
    end

    it "отставание раскладывается на цену долей и цену онлайн-решений без остатка" do
      expect(bound.share_loss + bound.online_loss).to be_within(1e-9).of(bound.free_optimum - bound.ours)
    end

    # Регресс: доли у роутера — мягкая цель, поэтому на длинной очереди он законно обходит
    # quota_optimum. Если считать долю оптимума от него, метрика вылезает за 100%.
    it "роутер, обошедший оптимум с жёсткими долями, не даёт больше 100% и показывает это минусом" do
      beat = PayoutRouter::Analytics::AssignmentBound::Result.new(
        operations: 200, ours: 147.74, all_to_self: 190.0, free_optimum: 157.0, quota_optimum: 141.77,
        worst: 90.0, quotas: {}, self_budget: 0, eligible_pairs: 12
      )

      expect(beat.score_vs_optimum).to be_within(0.01).of(94.1)
      expect(beat.online_loss).to be_negative
      expect(beat.share_loss + beat.online_loss).to be_within(1e-9).of(beat.free_optimum - beat.ours)
    end

    it "формулировка называет обе величины сравнения, чтобы цифру нельзя было прочитать в отрыве" do
      expect(bound.headline).to include(bound.ours.round(2).to_s, bound.free_optimum.round(2).to_s,
                                        "min-cost flow")
    end
  end

  describe PayoutRouter::Analytics::MinCostFlow do
    it "решает транспортную задачу точно: два источника, два стока, разная стоимость" do
      flow = described_class.new(6)
      flow.add(4, 0, 2, 0.0)
      flow.add(4, 1, 2, 0.0)
      flow.add(0, 2, 5, -1.0) # выгодная пара
      flow.add(0, 3, 5, -0.1)
      flow.add(1, 2, 5, -0.2)
      flow.add(1, 3, 5, -0.3)
      flow.add(2, 5, 2, 0.0)
      flow.add(3, 5, 2, 0.0)

      # обе единицы первого источника уходят во второй узел (−1 каждая), второго — в третий (−0.3)
      expect(flow.run(4, 5)).to be_within(1e-9).of(-2.6)
    end

    it "с profitable_only не тянет поток по невыгодным рёбрам" do
      flow = described_class.new(4)
      flow.add(3, 0, 2, 0.0)
      flow.add(0, 1, 2, 0.5) # положительная стоимость — гнать поток невыгодно
      flow.add(1, 2, 2, 0.0)

      expect(flow.run(3, 2, profitable_only: true)).to eq(0.0)
      expect(flow.run(3, 2)).to be_within(1e-9).of(1.0)
    end

    it "останавливается, когда сток недостижим" do
      flow = described_class.new(3)
      flow.add(0, 1, 1, 1.0)

      expect(flow.run(0, 2)).to eq(0.0)
    end
  end
end
