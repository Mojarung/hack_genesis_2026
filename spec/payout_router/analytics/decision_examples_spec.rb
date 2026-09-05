# frozen_string_literal: true

RSpec.describe PayoutRouter::Analytics::DecisionExamples do
  let(:vipay) { build_provider(name: "vipay", priority: 1, traffic_percentage: 60, conversion_24h: 0.9) }
  let(:payflow) { build_provider(name: "payflow", priority: 2, traffic_percentage: 40, limit_amount_max: 20_000) }
  let(:providers) { [vipay, payflow, build_fallback(name: "spacepayments")] }
  let(:policy) { build_policy("fallback_provider" => "spacepayments", "goals" => { "traffic_share" => 1.0 }) }

  def route(operations, simulator: PayoutRouter::Simulation::Optimistic.new)
    route_all(providers: providers, operations: operations, policy: policy, simulator: simulator).decisions
  end

  it "показывает выбор среди нескольких допустимых с причиной у каждого" do
    decisions = route([build_operation(id: "op_1", amount: 10_000)])

    example = described_class.new(decisions: decisions).call.fetch("choice_among_several")

    expect(example["operation"]).to include("operation_id" => "op_1", "amount" => 10_000)
    expect(example["selected"]).to include("provider" => "vipay", "reason" => "best_score")
    expect(example["skipped"].map { |row| row["reason"] }).to include("lower_score")
    expect(example["source"]).to include("composite_scorer.rb")
  end

  it "показывает случай, когда hard-правила оставили одного кандидата" do
    decisions = route([build_operation(id: "op_big", amount: 90_000)])

    example = described_class.new(decisions: decisions).call.fetch("single_eligible")

    expect(example["selected"]).to include("provider" => "vipay", "reason" => "only_eligible_provider")
    expect(example["skipped"].first).to include("provider" => "payflow", "reason" => "amount_exceeds_limit")
    expect(example["source"]).to include("pipeline.rb")
  end

  it "берёт переотправку и fallback из демонстрационного прогона с отказами" do
    dead = build_provider(name: "vipay", priority: 1, traffic_percentage: 60, conversion_24h: 0.0)
    cascade = route_all(providers: [dead, payflow, build_fallback(name: "spacepayments")],
                        operations: [build_operation(id: "op_fail", amount: 10_000)],
                        policy: policy,
                        simulator: PayoutRouter::Simulation::Conversion.new(seed: 1)).decisions

    cases = described_class.new(decisions: route([build_operation]), cascade_decisions: cascade).call

    expect(cases.fetch("retry_after_failure")["outcome"]).to include("retries" => 1)
    expect(cases.fetch("retry_after_failure")["skipped"]).to include(hash_including("dispatched" => true))
    expect(cases.fetch("retry_after_failure")["source"]).to include("try_ranked")
  end

  it "не выдумывает примеров, которых в прогоне не было" do
    cases = described_class.new(decisions: route([build_operation(id: "op_big", amount: 90_000)])).call

    expect(cases).to have_key("single_eligible")
    expect(cases).not_to have_key("retry_after_failure")
    expect(cases).not_to have_key("fallback_to_self_provider")
  end

  it "у каждого примера есть указание на место в коде" do
    decisions = route([build_operation(id: "op_1", amount: 10_000)])

    cases = described_class.new(decisions: decisions).call

    sources = cases.except("note").values.map { |example| example["source"] }
    expect(sources).to all(match(%r{lib/payout_router/.+\.rb}))
  end
end
