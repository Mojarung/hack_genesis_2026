# frozen_string_literal: true

RSpec.describe PayoutRouter::Simulation do
  let(:candidate) { build_candidate(build_provider(conversion_24h: 0.5, avg_latency_sec: 42)) }
  let(:settings) { PayoutRouter::Domain::Policy::SimulationSettings.new(mode: "conversion", seed: 11) }

  def expired_record(id, latency)
    PayoutRouter::Domain::HistoryRecord.new(operation_id: id, amount: 10, provider: "alpha", status: "expired",
                                            latency_sec: latency)
  end

  it "optimistic всегда одобряет за среднее время ответа" do
    outcome = described_class.build(settings.with(mode: "optimistic")).call(candidate, build_operation)
    expect(outcome).to have_attributes(result: "approved", latency_sec: 42)
  end

  it "conversion воспроизводим при одинаковом seed" do
    runs = Array.new(2) do
      simulator = described_class.build(settings)
      Array.new(30) { simulator.call(candidate, build_operation).result }
    end

    expect(runs.first).to eq(runs.last)
    expect(runs.first.uniq).to include("approved")
    expect(runs.first.uniq - %w[approved rejected expired]).to be_empty
  end

  it "conversion 1.0 никогда не отказывает, 0.0 — никогда не одобряет" do
    always = build_candidate(build_provider(conversion_24h: 1.0))
    never = build_candidate(build_provider(conversion_24h: 0.0))
    simulator = described_class.build(settings)

    expect(Array.new(20) { simulator.call(always, build_operation).result }.uniq).to eq(["approved"])
    expect(Array.new(20) { simulator.call(never, build_operation).result }.uniq).not_to include("approved")
  end

  it "берёт долю и задержку таймаутов из истории" do
    history = PayoutRouter::Analytics::HistoryStats.new([expired_record("1", 700), expired_record("2", 500)])
    simulator = described_class.build(settings, history_stats: history)
    outcomes = Array.new(20) { simulator.call(build_candidate(build_provider(conversion_24h: 0.0)), build_operation) }

    expect(outcomes.map(&:result).uniq).to eq(["expired"])
    expect(outcomes.first.latency_sec).to eq(600)
  end

  it "отвергает неизвестный режим" do
    expect { described_class.build(settings.with(mode: "magic")) }.to raise_error(PayoutRouter::PolicyError, /magic/)
  end
end
