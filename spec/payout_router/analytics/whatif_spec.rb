# frozen_string_literal: true

RSpec.describe "что-если анализ" do
  let(:runner) { default_runner }
  let(:operations) { runner.load_queue(data_path("operations_queue_10.json")) }

  describe PayoutRouter::Analytics::Backtest do
    let(:result) { runner.backtest }

    it "прогоняет всю историю и считает ожидаемые одобрения для обоих роутингов" do
      expect(result.operations).to eq(100)
      expect(result.actual_approved).to eq(runner.history_records.count(&:approved?))
      expect(result.expected_actual).to be_between(40, 100)
      expect(result.expected_ours).to be_between(40, 100)
      expect(result.decisions).to all(be_routed)
    end

    it "сериализует итог с методом оценки" do
      serialized = result.serialize
      expect(serialized["uplift_approvals"]).to eq((result.expected_ours - result.expected_actual).round(2))
      expect(serialized["by_provider"].keys).to include("vipay", "payflow", "quickpay")
      expect(serialized["method"]).to include("leave-one-out")
    end

    it "не считается без истории" do
      empty = default_runner(history_path: nil)
      expect { empty.backtest }.to raise_error(PayoutRouter::InputError, /история пуста/)
    end
  end

  describe PayoutRouter::Analytics::PolicyComparison do
    it "даёт метрики по каждой политике на одной очереди" do
      policies = runner.load_policies([config_path("policy.yml"), config_path("policies/cascade.yml")])
      rows = runner.comparison(operations).call(policies)

      expect(rows.map { |row| row.policy.name }).to eq(%w[balanced cascade])
      balanced = rows.first
      expect(balanced.distribution["vipay"]).to include("count" => 4, "target_pct" => 40)
      expect(balanced.deviation_pp).to be_within(0.01).of(10.0)
      expect(balanced.expected_conversion).to be_between(0.4, 1.0)
      expect(balanced.serialize).to include("expected_margin_rub", "avg_latency_sec")
    end
  end

  describe PayoutRouter::Analytics::MonteCarlo do
    it "воспроизводим при одном seed и даёт перцентили" do
      first = runner.monte_carlo(operations, runs: 15, seed: 3)
      second = runner.monte_carlo(operations, runs: 15, seed: 3)

      expect(first.serialize).to eq(second.serialize)
      expect(first.approved["mean"]).to be_between(5, 10)
      expect(first.approved["p5"]).to be <= first.approved["p95"]
      expect(first.shares.keys).to include("vipay", "spacepayments")
    end
  end

  describe PayoutRouter::Analytics::WeightTuner do
    it "не ухудшает целевую функцию и сохраняет веса в политике" do
      result = runner.tune(operations, candidates: 8, seed: 5)

      expect(result.after.value).to be <= result.before.value
      expect(result.policy.goals.values.sum).to be_within(0.2).of(1.0)
      expect(result.policy.name).to eq("balanced_tuned")
      expect(result.evaluations).to be > 8
      expect(PayoutRouter::Inputs::PolicyLoader.from_hash(result.policy.to_h_document).goals).to eq(result.policy.goals)
    end

    it "строит синтетическую очередь из истории" do
      queue = runner.synthetic_queue(50, seed: 2)
      expect(queue.size).to eq(50)
      expect(queue.map(&:bank).uniq).to all(be_a(String))
      expect(queue.each_cons(2).all? { |a, b| b.created_at > a.created_at }).to be(true)
    end
  end
end
