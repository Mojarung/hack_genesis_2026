# frozen_string_literal: true

RSpec.describe PayoutRouter::Domain::Policy do
  let(:policy) do
    build_policy(
      "amount_bands" => [{ "min" => 500, "max" => 50_000, "prefer" => ["beta"] },
                         { "min" => 50_001, "max" => nil, "prefer" => ["alpha"] }],
      "providers" => { "alpha" => { "requests_per_minute_limit" => 7, "daily_turnover_min" => 2_000_000 } }
    )
  end

  it "накладывает параметры политики и флаг fallback на провайдеров снимка" do
    snapshot = policy.apply(build_snapshot(build_provider(name: "alpha"), build_provider(name: "self")))
    alpha = snapshot.provider("alpha")

    expect(alpha.requests_per_minute_limit).to eq(7)
    expect(alpha.daily_turnover_min).to eq(2_000_000)
    expect(alpha.fallback?).to be(false)
    expect(snapshot.provider("self").fallback?).to be(true)
    expect(snapshot.external.map(&:name)).to eq(["alpha"])
  end

  it "находит диапазон суммы, включая открытую верхнюю границу" do
    expect(policy.band_for(10_000).prefer).to eq(["beta"])
    expect(policy.band_for(1_000_000).prefer).to eq(["alpha"])
    expect(policy.band_for(100)).to be_nil
  end

  it "сообщает о провайдерах из политики, которых нет в снимке" do
    expect(policy.unknown_providers(build_snapshot(build_provider(name: "beta")))).to eq(["alpha"])
  end

  it "исключает цели с нулевым весом" do
    policy = build_policy("goals" => { "traffic_share" => 0.5, "latency" => 0 })
    expect(policy.enabled_goals.keys).to eq(["traffic_share"])
  end
end
