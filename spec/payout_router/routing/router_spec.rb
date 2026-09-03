# frozen_string_literal: true

RSpec.describe PayoutRouter::Routing::Router do
  let(:reasons) { PayoutRouter::Routing::Reasons }
  let(:alpha) { build_provider(name: "alpha", priority: 1, traffic_percentage: 60, banks: %w[sberbank vtb]) }
  let(:beta) { build_provider(name: "beta", priority: 2, traffic_percentage: 40, limit_amount_max: 50_000) }
  let(:fallback) { build_fallback }

  def decide(operation, providers: [alpha, beta, fallback], policy: build_policy, simulator: PayoutRouter::Simulation::Optimistic.new)
    route_all(providers: providers, operations: [operation], policy: policy, simulator: simulator).decisions.first
  end

  it "уходит на fallback, когда внешние не прошли hard-правила, и объясняет отсев каждого" do
    decision = decide(build_operation(amount: 80_000, bank: "alfa"))

    expect(decision.selected_provider).to eq("self")
    expect(decision.reason).to eq(reasons::FALLBACK_SELF_PROVIDER)
    expect(decision.attempts.map { |a| [a.provider, a.decision, a.reason] }).to eq(
      [["alpha", "skipped", reasons::BANK_NOT_IN_LIST], ["beta", "skipped", reasons::AMOUNT_EXCEEDS_LIMIT],
       ["self", "selected", reasons::FALLBACK_SELF_PROVIDER]]
    )
    expect(decision.fallback_used).to be(true)
    expect(decision.attempts.last.details).to include("alpha: bank_not_in_list; beta: amount_exceeds_limit")
  end

  it "среди нескольких допустимых берёт лучший скор и помечает проигравших" do
    decision = decide(build_operation(amount: 10_000, bank: "sberbank"))

    expect(decision.selected_provider).to eq("alpha")
    expect(decision.reason).to eq(reasons::BEST_SCORE)
    loser = decision.attempts.find { |a| a.provider == "beta" }
    expect(loser.reason).to eq(reasons::LOWER_SCORE)
    expect(loser.details).to match(/score [\d.]+ < [\d.]+ \(alpha\)/)
    expect(decision.attempts.first.breakdown).to have_key("traffic_share")
  end

  it "ставит only_eligible_provider, когда допустим один" do
    decision = decide(build_operation(amount: 80_000, bank: "sberbank"))
    expect(decision.selected_provider).to eq("alpha")
    expect(decision.reason).to eq(reasons::ONLY_ELIGIBLE)
  end

  it "после отказа идёт к следующему по рангу и фиксирует повтор" do
    decision = decide(build_operation(amount: 10_000, bank: "sberbank"),
                      simulator: ScriptedSimulator.new("rejected", "approved"))

    expect(decision.attempts.map { |a| [a.provider, a.decision, a.reason] }).to eq(
      [["alpha", "skipped", reasons::PROVIDER_REJECTED], ["beta", "selected", reasons::FALLBACK_AFTER_FAILURE]]
    )
    expect(decision.selected_provider).to eq("beta")
    expect(decision.retries).to eq(1)
    expect(decision.attempts.first.simulated_result).to eq("rejected")
    expect(decision.simulated_result).to eq("approved")
  end

  it "таймаут тоже ведёт к следующему провайдеру, а когда внешние кончились — к fallback" do
    decision = decide(build_operation(amount: 10_000, bank: "sberbank"),
                      simulator: ScriptedSimulator.new("expired", "rejected", "approved"))

    expect(decision.attempts.map(&:reason)).to eq([reasons::PROVIDER_TIMEOUT, reasons::PROVIDER_REJECTED,
                                                   reasons::FALLBACK_SELF_PROVIDER])
    expect(decision.selected_provider).to eq("self")
    expect(decision.retries).to eq(2)
  end

  it "без fallback и допустимых провайдеров заявка остаётся без маршрута" do
    decision = decide(build_operation(amount: 80_000, bank: "alfa"), providers: [alpha, beta])

    expect(decision.selected_provider).to be_nil
    expect(decision.reason).to eq(reasons::NO_ELIGIBLE_PROVIDER)
    expect(decision.simulated_result).to eq("rejected")
    expect(decision.serialize).to include("selected_provider" => nil, "operation_id" => "op_1")
  end

  it "проверяет hard-правила и у fallback-провайдера" do
    paused = build_fallback.with(status: "paused")
    decision = decide(build_operation(amount: 80_000, bank: "alfa"), providers: [alpha, beta, paused])
    expect(decision.attempts.last).to have_attributes(provider: "self", reason: reasons::PROVIDER_INACTIVE)
    expect(decision).not_to be_routed
  end

  it "обновляет состояние: одобренный оборот закрывает дневной лимит следующим заявкам" do
    tight = build_provider(name: "alpha", daily_amount_limit: 25_000, daily_approved_amount: 10_000,
                           avg_latency_sec: 10)
    operations = [build_operation(id: "a", amount: 12_000, at: Builders::T0),
                  build_operation(id: "b", amount: 12_000, at: Builders::T0 + 60)]
    decisions = route_all(providers: [tight, fallback], operations: operations).decisions

    expect(decisions.first.selected_provider).to eq("alpha")
    expect(decisions.last.attempts.first).to have_attributes(provider: "alpha", reason: reasons::DAILY_LIMIT_EXCEEDED)
    expect(decisions.last.attempts.first.details).to include("22000 + 12000 > daily_amount_limit 25000")
  end

  it "держит лимит одновременных заявок, пока ответы не пришли" do
    narrow = build_provider(name: "alpha", in_progress_count_limit: 1, avg_latency_sec: 30)
    operations = [build_operation(id: "a", at: Builders::T0), build_operation(id: "b", at: Builders::T0 + 5),
                  build_operation(id: "c", at: Builders::T0 + 40)]
    decisions = route_all(providers: [narrow, fallback], operations: operations).decisions

    expect(decisions.map(&:selected_provider)).to eq(%w[alpha self alpha])
    expect(decisions[1].attempts.first.reason).to eq(reasons::IN_PROGRESS_COUNT_LIMIT)
  end

  it "соблюдает лимит интенсивности из политики" do
    policy = build_policy("providers" => { "alpha" => { "requests_per_minute_limit" => 1 } })
    operations = [build_operation(id: "a", at: Builders::T0), build_operation(id: "b", at: Builders::T0 + 20)]
    decisions = route_all(providers: [alpha, fallback], operations: operations, policy: policy).decisions

    expect(decisions.last.attempts.first).to have_attributes(provider: "alpha", reason: reasons::RATE_LIMIT_EXCEEDED)
  end

  it "обрабатывает заявки хронологически, а отдаёт в порядке входа" do
    later = build_operation(id: "later", at: Builders::T0 + 100)
    earlier = build_operation(id: "earlier", at: Builders::T0)
    decisions = route_all(providers: [alpha, fallback], operations: [later, earlier]).decisions

    expect(decisions.map(&:operation_id)).to eq(%w[later earlier])
    first_attempt = decisions.last.attempts.first
    expect(first_attempt.breakdown["traffic_share"]["note"]).to include("count share 0.0%")
  end

  it "в каскадной политике порядок задаёт priority" do
    policy = build_policy("goals" => { "cascade_priority" => 1 })
    decision = decide(build_operation(amount: 10_000, bank: "sberbank"), policy: policy)
    expect(decision.selected_provider).to eq("alpha")
    expect(decision.attempts.first.breakdown.keys).to eq(["cascade_priority"])
  end
end
