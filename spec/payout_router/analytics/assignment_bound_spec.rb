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
