# frozen_string_literal: true

RSpec.describe PayoutRouter::Scoring::ChainScorer do
  let(:alpha) { build_provider(name: "alpha", priority: 1, traffic_percentage: 50, conversion_24h: 0.80) }
  let(:beta) { build_provider(name: "beta", priority: 2, traffic_percentage: 50, conversion_24h: 0.95) }
  let(:gamma) { build_provider(name: "gamma", priority: 3, traffic_percentage: 0, conversion_24h: 0.70) }
  let(:snapshot) { build_snapshot(alpha, beta, gamma) }
  let(:ledger) { PayoutRouter::State::Ledger.new(snapshot) }
  let(:candidates) do
    [alpha, beta, gamma].map { |p| PayoutRouter::Routing::Candidate.new(provider: p, state: ledger.state(p.name)) }
  end
  let(:bands) { [{ "min" => 0, "max" => 20_000, "prefer" => ["gamma"] }] }

  def context(amount: 10_000)
    PayoutRouter::Scoring::Context.new(operation: build_operation(amount: amount), ledger: ledger, now: Builders::T0)
  end

  def policy(chain, amount_bands: bands)
    build_policy("selection" => { "mode" => "chain", "chain" => chain }, "goals" => {}, "amount_bands" => amount_bands,
                 "tie_breakers" => %w[priority name])
  end

  def rank(chain, amount: 10_000)
    described_class.new(policy: policy(chain), snapshot: snapshot).rank(candidates, context(amount: amount))
  end

  it "первая применимая стратегия решает, остальные не консультируются" do
    ranked = rank([{ "strategy" => "amount_band" }, { "strategy" => "conversion" }])

    expect(ranked.map(&:name)).to eq(%w[gamma beta alpha])
    winner = ranked.first
    expect(winner.total).to eq(1.0)
    expect(winner.breakdown["1·amount_band"]).to include("weight" => 1.0)
    expect(winner.breakdown["1·amount_band"]["note"]).to include("decisive step")
    expect(winner.summary).to include("decisive: 1·amount_band")
  end

  it "при равенстве на первом шаге решает следующая стратегия" do
    ranked = rank([{ "strategy" => "amount_band" }, { "strategy" => "conversion" }], amount: 90_000)

    expect(ranked.map(&:name)).to eq(%w[beta alpha gamma])
    expect(ranked.first.breakdown["1·amount_band"]["note"]).to include("tie, passed to the next step")
    expect(ranked.first.breakdown["2·conversion"]["note"]).to include("decisive step")
    expect(ranked.first.total).to eq(0.95)
  end

  it "tolerance превращает близкие оценки в равенство" do
    strict = rank([{ "strategy" => "conversion" }, { "strategy" => "cascade_priority" }])
    loose = rank([{ "strategy" => "conversion", "tolerance" => 0.2 }, { "strategy" => "cascade_priority" }])

    expect(strict.map(&:name)).to eq(%w[beta alpha gamma])
    expect(loose.map(&:name)).to eq(%w[alpha beta gamma])
  end

  it "после всех шагов решают tie-breakers" do
    ranked = rank([{ "strategy" => "amount_band" }], amount: 90_000)
    expect(ranked.map(&:name)).to eq(%w[alpha beta gamma])
    expect(ranked.first.breakdown["1·amount_band"]["note"]).to include("tie-breakers")
  end

  it "шаг может быть взвешенной группой" do
    ranked = rank([{ "goals" => { "conversion" => 0.5, "cascade_priority" => 0.5 } }])
    expect(ranked.first.name).to eq("alpha") # 0.8×0.5 + 1.0×0.5 = 0.9 против beta 0.95×0.5 + 0.5×0.5 = 0.725
    expect(ranked.first.breakdown.keys).to eq(["1·(conversion 0.5, cascade_priority 0.5)"])
  end

  it "не создаётся с пустой цепочкой и требует известных стратегий" do
    expect { build_policy("selection" => { "mode" => "chain", "chain" => [] }, "goals" => {}) }
      .to raise_error(PayoutRouter::PolicyError, /непустой selection.chain/)
    expect { build_policy("selection" => { "mode" => "chain", "chain" => [{ "strategy" => "nope" }] }, "goals" => {}) }
      .to raise_error(PayoutRouter::PolicyError, /неизвестная цель «nope»/)
  end
end
