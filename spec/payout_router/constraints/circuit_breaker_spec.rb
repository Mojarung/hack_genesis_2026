# frozen_string_literal: true

RSpec.describe PayoutRouter::Constraints::CircuitBreaker do
  let(:reasons) { PayoutRouter::Routing::Reasons }
  let(:alpha) { build_provider(name: "alpha", priority: 1, avg_latency_sec: 10) }
  let(:beta) { build_provider(name: "beta", priority: 2, avg_latency_sec: 10) }
  let(:policy) do
    build_policy("goals" => { "cascade_priority" => 1 },
                 "circuit_breaker" => { "failures" => 2, "cooldown_sec" => 120 })
  end
  let(:operations) do
    [Builders::T0, Builders::T0 + 30, Builders::T0 + 60, Builders::T0 + 200].each_with_index.map do |at, index|
      build_operation(id: "op#{index}", at: at)
    end
  end
  # alpha отказывает дважды (op0, op1) → карантин с момента второго ответа (T0+40) до T0+160.
  let(:result) do
    simulator = ScriptedSimulator.new("rejected", "approved", "rejected", "approved", "approved", "approved")
    route_all(providers: [alpha, beta, build_fallback], operations: operations, policy: policy, simulator: simulator)
  end

  it "после серии отказов выводит провайдера из ротации на время паузы" do
    decisions = result.decisions
    third = decisions[2].attempts.first

    expect(decisions[1].attempts.map(&:reason)).to eq([reasons::PROVIDER_REJECTED, reasons::FALLBACK_AFTER_FAILURE])
    expect(third).to have_attributes(provider: "alpha", reason: reasons::CIRCUIT_OPEN)
    expect(third.details).to include("after 2 consecutive failures (trip #1)")
    expect(decisions[2].selected_provider).to eq("beta")
  end

  it "возвращает провайдера после паузы и считает срабатывания" do
    expect(result.decisions[3].selected_provider).to eq("alpha")
    expect(result.ledger.state("alpha").circuit_trips).to eq(1)
  end

  it "одобрение сбрасывает серию" do
    state = PayoutRouter::State::ProviderState.new(alpha, breaker: policy.circuit_breaker)
    outcome = ->(status) { PayoutRouter::Simulation::Outcome.new(result: status, latency_sec: 1) }
    %w[rejected approved expired].each do |status|
      state.dispatch!(build_operation, Builders::T0)
      state.settle!(build_operation, outcome.call(status), at: Builders::T0)
    end

    expect(state.consecutive_failures).to eq(1)
    expect(state.circuit_open?(Builders::T0)).to be(false)
  end

  it "выключается нулевым числом отказов и валидирует настройки" do
    off = build_policy("circuit_breaker" => { "failures" => 0 })
    expect(off.circuit_breaker).not_to be_enabled
    expect { build_policy("circuit_breaker" => { "failures" => "many" }) }
      .to raise_error(PayoutRouter::PolicyError, /circuit_breaker/)
  end
end
