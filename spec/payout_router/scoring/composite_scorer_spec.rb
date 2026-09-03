# frozen_string_literal: true

RSpec.describe PayoutRouter::Scoring::CompositeScorer do
  let(:alpha) { build_provider(name: "alpha", priority: 1, conversion_24h: 0.80, traffic_percentage: 50) }
  let(:beta) { build_provider(name: "beta", priority: 2, conversion_24h: 0.95, traffic_percentage: 50) }
  let(:snapshot) { build_snapshot(alpha, beta) }
  let(:ledger) { PayoutRouter::State::Ledger.new(snapshot) }
  let(:context) { PayoutRouter::Scoring::Context.new(operation: build_operation, ledger: ledger, now: Builders::T0) }
  let(:candidates) { [alpha, beta].map { |provider| PayoutRouter::Routing::Candidate.new(provider: provider, state: ledger.state(provider.name)) } }

  def rank(policy, pool = candidates) = described_class.new(policy: policy, snapshot: snapshot).rank(pool, context)

  it "pool: оценка каждой цели приводится к разбросу среди кандидатов, вес — важность цели" do
    ranked = rank(build_policy("goals" => { "conversion" => 3, "cascade_priority" => 1 }))

    # conversion: alpha 0.80 → 0, beta 0.95 → 1; cascade_priority: alpha 1, beta 0
    expect(ranked.map(&:name)).to eq(%w[beta alpha])
    expect(ranked.first.total).to be_within(0.0001).of(3.0 / 4)
    expect(ranked.last.total).to be_within(0.0001).of(1.0 / 4)
    expect(ranked.first.breakdown["conversion"]).to include("score" => 0.95, "normalized" => 1.0, "weight" => 3.0)
  end

  it "absolute: оценки стратегий как есть, итог = Σ(вес × оценка) / Σ весов" do
    policy = build_policy("goals" => { "conversion" => 3, "cascade_priority" => 1 },
                          "selection" => { "normalization" => "absolute" })
    ranked = rank(policy)

    expect(ranked.map(&:name)).to eq(%w[alpha beta])
    expect(ranked.first.total).to be_within(0.0001).of(((0.80 * 3) + (1.0 * 1)) / 4)
    expect(ranked.last.total).to be_within(0.0001).of((0.95 * 3) / 4)
    expect(ranked.last.breakdown["conversion"]).to include("weight" => 3.0, "score" => 0.95)
    expect(ranked.last.breakdown["conversion"]).not_to have_key("normalized")
  end

  it "цель, не различающая кандидатов, даёт всем 0.5; единственный кандидат оценивается как есть" do
    ranked = rank(build_policy("goals" => { "traffic_share" => 1, "conversion" => 1 }))
    expect(ranked.map { |score| score.breakdown["traffic_share"]["normalized"] }).to all(eq(0.5))

    alone = rank(build_policy("goals" => { "conversion" => 1 }), candidates.first(1))
    expect(alone.first.breakdown["conversion"]).to include("score" => 0.8)
    expect(alone.first.breakdown["conversion"]).not_to have_key("normalized")
  end

  it "при равном скоре решает tie-breaker из политики" do
    by_priority = rank(build_policy("goals" => { "traffic_share" => 1 }, "tie_breakers" => ["priority"]))
    by_conversion = rank(build_policy("goals" => { "traffic_share" => 1 }, "tie_breakers" => ["conversion"]))

    expect(by_priority.map(&:name)).to eq(%w[alpha beta])
    expect(by_conversion.map(&:name)).to eq(%w[beta alpha])
  end

  it "summary называет решающие цели — относительно соперника только те, что дали перевес" do
    ranked = rank(build_policy("goals" => { "conversion" => 0.7, "cascade_priority" => 0.3 }))
    winner, runner_up = ranked

    expect(winner.summary).to match(/score 0\.\d+; decisive: conversion/)
    expect(winner.summary(versus: runner_up)).to eq("score 0.7; decisive vs alpha: conversion (+0.7)")
  end

  it "не даёт создать скорер без целей" do
    policy = build_policy.with(goals: { "conversion" => 0.0 })
    expect do
      described_class.new(policy: policy, snapshot: snapshot)
    end.to raise_error(PayoutRouter::PolicyError, /ни одна цель/)
  end
end
