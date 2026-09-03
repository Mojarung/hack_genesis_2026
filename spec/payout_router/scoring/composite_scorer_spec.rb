# frozen_string_literal: true

RSpec.describe PayoutRouter::Scoring::CompositeScorer do
  let(:alpha) { build_provider(name: "alpha", priority: 1, conversion_24h: 0.80, traffic_percentage: 50) }
  let(:beta) { build_provider(name: "beta", priority: 2, conversion_24h: 0.95, traffic_percentage: 50) }
  let(:snapshot) { build_snapshot(alpha, beta) }
  let(:ledger) { PayoutRouter::State::Ledger.new(snapshot) }
  let(:context) { PayoutRouter::Scoring::Context.new(operation: build_operation, ledger: ledger, now: Builders::T0) }
  let(:candidates) { [alpha, beta].map { |provider| PayoutRouter::Routing::Candidate.new(provider: provider, state: ledger.state(provider.name)) } }

  def rank(policy) = described_class.new(policy: policy, snapshot: snapshot).rank(candidates, context)

  it "нормализует веса: итог = Σ(вес × оценка) / Σ весов" do
    ranked = rank(build_policy("goals" => { "conversion" => 3, "cascade_priority" => 1 }))

    expect(ranked.map(&:name)).to eq(%w[alpha beta])
    expect(ranked.first.total).to be_within(0.0001).of(((0.80 * 3) + (1.0 * 1)) / 4)
    expect(ranked.last.total).to be_within(0.0001).of((0.95 * 3) / 4)
    expect(ranked.last.breakdown["conversion"]).to include("weight" => 3.0, "score" => 0.95)
  end

  it "при равном скоре решает tie-breaker из политики" do
    by_priority = rank(build_policy("goals" => { "traffic_share" => 1 }, "tie_breakers" => ["priority"]))
    by_conversion = rank(build_policy("goals" => { "traffic_share" => 1 }, "tie_breakers" => ["conversion"]))

    expect(by_priority.map(&:name)).to eq(%w[alpha beta])
    expect(by_conversion.map(&:name)).to eq(%w[beta alpha])
  end

  it "объясняет решающие цели в summary" do
    ranked = rank(build_policy("goals" => { "conversion" => 0.7, "cascade_priority" => 0.3 }))
    expect(ranked.first.summary).to match(/score 0\.\d+; decisive: conversion/)
  end

  it "не даёт создать скорер без целей" do
    policy = build_policy.with(goals: { "conversion" => 0.0 })
    expect do
      described_class.new(policy: policy, snapshot: snapshot)
    end.to raise_error(PayoutRouter::PolicyError, /ни одна цель/)
  end
end
