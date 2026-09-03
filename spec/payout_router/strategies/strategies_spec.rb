# frozen_string_literal: true

RSpec.describe "soft-goals" do
  let(:alpha) do
    build_provider(name: "alpha", traffic_percentage: 40, priority: 1, conversion_24h: 0.87, avg_latency_sec: 40)
  end
  let(:beta) do
    build_provider(name: "beta", traffic_percentage: 60, priority: 2, conversion_24h: 0.91, avg_latency_sec: 80)
  end
  let(:snapshot) { build_snapshot(alpha, beta, build_fallback) }
  let(:ledger) { PayoutRouter::State::Ledger.new(snapshot) }
  let(:policy) { build_policy("amount_bands" => [{ "min" => 0, "max" => 50_000, "prefer" => ["beta"] }]) }

  def context(operation = build_operation, with: ledger)
    PayoutRouter::Scoring::Context.new(operation: operation, ledger: with, now: operation.created_at)
  end

  # Оценка провайдера из общего снимка (alpha/beta) с общим леджером.
  def evaluate(strategy_class, provider, operation = build_operation)
    candidate = PayoutRouter::Routing::Candidate.new(provider: provider, state: ledger.state(provider.name))
    strategy_class.new(policy: policy, snapshot: snapshot).evaluate(candidate, context(operation))
  end

  # Оценка произвольного провайдера со своим леджером (для сценариев с загрузкой/лимитами).
  def evaluate_alone(strategy_class, provider, prepare: nil)
    own = PayoutRouter::State::Ledger.new(build_snapshot(provider))
    prepare&.call(own)
    candidate = PayoutRouter::Routing::Candidate.new(provider: provider, state: own.state(provider.name))
    strategy_class.new(policy: policy, snapshot: snapshot).evaluate(candidate, context(with: own))
  end

  it "traffic_share: недобор поднимает оценку, перебор опускает" do
    expect(evaluate(PayoutRouter::Strategies::TrafficShare, alpha).score).to eq(0.9)
    ledger.select!(ledger.state("alpha"), build_operation)
    signal = evaluate(PayoutRouter::Strategies::TrafficShare, alpha)
    expect(signal.score).to eq(0.0)
    expect(signal.note).to include("100.0% vs target 40.0%")
  end

  it "volume_share: учитывает объём из снимка" do
    signal = evaluate(PayoutRouter::Strategies::VolumeShare, alpha)
    expect(signal.score).to eq(0.9)
    expect(signal.note).to include("volume share 0.0%")
  end

  it "cascade_priority: первый по priority получает 1, последний — 0" do
    expect(evaluate(PayoutRouter::Strategies::CascadePriority, alpha).score).to eq(1.0)
    expect(evaluate(PayoutRouter::Strategies::CascadePriority, beta).score).to eq(0.0)
  end

  it "amount_band: предпочтительный провайдер диапазона получает 1, остальные 0, вне диапазона 0.5" do
    expect(evaluate(PayoutRouter::Strategies::AmountBand, beta).score).to eq(1.0)
    expect(evaluate(PayoutRouter::Strategies::AmountBand, alpha).score).to eq(0.0)
    expect(evaluate(PayoutRouter::Strategies::AmountBand, alpha, build_operation(amount: 90_000)).score).to eq(0.5)
  end

  it "conversion: равна conversion_24h" do
    expect(evaluate(PayoutRouter::Strategies::Conversion, beta).score).to eq(0.91)
  end

  it "load: падает с ростом худшей загрузки" do
    loaded = build_provider(name: "alpha", daily_amount_limit: 1_000, daily_approved_amount: 900)
    signal = evaluate_alone(PayoutRouter::Strategies::Load, loaded)
    expect(signal.score).to be_within(0.001).of(0.1)
    expect(signal.note).to include("daily 90.0%")
  end

  it "turnover_min: нейтральна без обязательства, растёт при недоборе" do
    expect(evaluate(PayoutRouter::Strategies::TurnoverMin, alpha).score).to eq(0.5)
    obliged = build_provider(name: "alpha", daily_turnover_min: 1_000, daily_approved_amount: 250)
    expect(evaluate_alone(PayoutRouter::Strategies::TurnoverMin, obliged).score).to eq(0.875)
  end

  it "rate_headroom: 1 без лимита, уменьшается с отправками" do
    expect(evaluate(PayoutRouter::Strategies::RateHeadroom, alpha).score).to eq(1.0)
    limited = build_provider(name: "alpha", requests_per_minute_limit: 4)
    outcome = PayoutRouter::Simulation::Outcome.new(result: "approved", latency_sec: 1)
    dispatch = ->(own) { own.dispatch!(own.state("alpha"), build_operation, outcome, Builders::T0) }
    expect(evaluate_alone(PayoutRouter::Strategies::RateHeadroom, limited, prepare: dispatch).score).to eq(0.75)
  end

  it "latency и margin: быстрее и дешевле — выше" do
    expect(evaluate(PayoutRouter::Strategies::Latency, alpha).score).to eq(0.5)
    expect(evaluate(PayoutRouter::Strategies::Latency, beta).score).to eq(0.0)
    expect(evaluate(PayoutRouter::Strategies::Margin, alpha).score).to be_within(0.001).of(1.0 / 3)
  end

  it "оценка всегда в пределах 0..1" do
    over = build_provider(name: "alpha", traffic_percentage: 100)
    ledger.select!(ledger.state("alpha"), build_operation)
    expect(evaluate(PayoutRouter::Strategies::TrafficShare, over).score).to be_between(0.0, 1.0)
  end
end
