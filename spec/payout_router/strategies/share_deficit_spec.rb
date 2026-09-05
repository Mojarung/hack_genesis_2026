# frozen_string_literal: true

RSpec.describe PayoutRouter::Strategies::ShareDeficit do
  let(:alpha) { build_provider(name: "alpha", priority: 1, traffic_percentage: 70) }
  let(:beta) { build_provider(name: "beta", priority: 2, traffic_percentage: 30) }
  let(:snapshot) { build_snapshot(alpha, beta) }
  let(:ledger) { PayoutRouter::State::Ledger.new(snapshot) }
  let(:policy) { build_policy("goals" => { "share_deficit" => 1.0 }) }
  let(:context) { PayoutRouter::Scoring::Context.new(operation: build_operation, ledger: ledger, now: Builders::T0) }

  def score(provider)
    described_class.new(policy: policy, snapshot: snapshot)
                   .evaluate(PayoutRouter::Routing::Candidate.new(state: ledger.state(provider.name)), context)
  end

  it "на пустой сессии недобор пропорционален цели: у кого доля больше, тот и впереди" do
    expect(score(alpha).score).to be > score(beta).score
    expect(score(alpha).note).to include("owed 0.70 of 1 ops, routed 0")
  end

  it "выданные заявки гасят недобор, и провайдер уступает" do
    3.times { |index| ledger.select!(ledger.state("alpha"), build_operation(id: "op_#{index}")) }

    # alpha: должен 0.7 × 4 = 2.8, выдано 3 → перебор; beta: должен 1.2, выдано 0 → недобор
    expect(score(alpha).score).to be < PayoutRouter::Strategies::Base::NEUTRAL
    expect(score(beta).score).to be > PayoutRouter::Strategies::Base::NEUTRAL
  end

  it "считает недобор в заявках, поэтому на длинной очереди сигнал сильнее, чем на короткой" do
    short = score(beta).score
    30.times { |index| ledger.select!(ledger.state("alpha"), build_operation(id: "long_#{index}")) }
    long = score(beta).score

    expect(long).to be > short
  end

  it "доли сходятся к цели точнее, чем процентная стратегия" do
    operations = Array.new(60) { |index| build_operation(id: "op_#{index}", at: Builders::T0 + (index * 60)) }
    deviation = lambda do |goal|
      result = route_all(providers: [alpha, beta, build_fallback], operations: operations,
                         policy: build_policy("goals" => { goal => 1.0 }))
      stats = PayoutRouter::Analytics::RoutingStats.new(decisions: result.decisions, ledger: result.ledger,
                                                        snapshot: build_snapshot(alpha, beta, build_fallback))
      [alpha, beta].sum { |provider| stats.distribution.dig(provider.name, "deviation_pp").to_f.abs }
    end

    expect(deviation.call("share_deficit")).to be <= deviation.call("traffic_share")
  end
end
