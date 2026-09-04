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

  it "при simulation.timeout: hold таймаут закрывает каскад и удерживает ёмкость провайдера" do
    policy = build_policy("simulation" => { "mode" => "optimistic", "timeout" => "hold" })
    result = route_all(providers: [alpha, beta, fallback], policy: policy,
                       operations: [build_operation(amount: 10_000, bank: "sberbank")],
                       simulator: ScriptedSimulator.new("expired", "approved"))
    decision = result.decisions.first

    expect([decision.selected_provider, decision.simulated_result, decision.retries]).to eq(["alpha", "expired", 0])
    expect(decision.attempts.first.details).to include("timeout without provider status")
    expect(decision.attempts.map { |a| [a.provider, a.decision] }).to eq([%w[alpha selected], %w[beta skipped]])

    held = result.ledger.state("alpha")
    expect([held.in_progress_count, held.held_timeout_count, held.daily_approved_amount]).to eq([1, 1, 0])
  end

  it "без fallback и допустимых провайдеров заявка остаётся без маршрута" do
    decision = decide(build_operation(amount: 80_000, bank: "alfa"), providers: [alpha, beta])

    expect(decision.selected_provider).to be_nil
    expect(decision.reason).to eq(reasons::NO_ELIGIBLE_PROVIDER)
    expect(decision.simulated_result).to eq("rejected")
    expect(decision.serialize).to include("selected_provider" => nil, "operation_id" => "op_1")
  end

  it "проверяет статические правила допуска и у fallback-провайдера" do
    paused = build_fallback.with(status: "paused")
    decision = decide(build_operation(amount: 80_000, bank: "alfa"), providers: [alpha, beta, paused])
    expect(decision.attempts.last).to have_attributes(provider: "self", reason: reasons::PROVIDER_INACTIVE)
    expect(decision).not_to be_routed
  end

  it "валюта заявки — hard-правило для всех, включая fallback" do
    rub = [alpha, beta, fallback].map { |provider| provider.with(currency: "RUB") }
    usd = PayoutRouter::Domain::Operation.new(operation_id: "usd", created_at: Builders::T0, amount: 10_000,
                                              bank: "sberbank", currency: "USD")
    decision = decide(usd, providers: rub)

    expect(decision.attempts.map(&:reason)).to all(eq(reasons::CURRENCY_MISMATCH))
    expect(decision.attempts.first.details).to eq("USD != provider currency RUB")
    expect(decision).not_to be_routed
    expect(decide(usd.with(currency: nil), providers: rub)).to be_routed
  end

  it "плотная очередь: ёмкость fallback не ограничивает, ни одна заявка не остаётся без маршрута" do
    narrow = build_provider(name: "alpha", in_progress_count_limit: 2, available_requisites: 5, avg_latency_sec: 60)
    scarce = build_fallback.with(available_requisites: 1)
    operations = (1..8).map { |i| build_operation(id: "op_#{i}", at: Builders::T0) } # одно время — ничего не сеттлится
    decisions = route_all(providers: [narrow, scarce], operations: operations).decisions

    expect(decisions.map(&:selected_provider)).to eq(%w[alpha alpha] + (["self"] * 6))
    expect(decisions.count(&:routed?)).to eq(8)
    fallback_attempts = decisions.last.attempts.select { |attempt| attempt.provider == "self" }
    expect(fallback_attempts.map(&:reason)).to eq([reasons::FALLBACK_SELF_PROVIDER])
  end

  it "fallback_constraints задаёт правила для fallback явно; пустой список — fallback безусловный" do
    policy = build_policy("fallback_constraints" => [])
    paused = build_fallback.with(status: "paused")
    decision = decide(build_operation(amount: 80_000, bank: "alfa"), providers: [alpha, beta, paused], policy: policy)
    expect(decision.selected_provider).to eq("self")

    strict = build_policy("fallback_constraints" => ["requisites"])
    empty = build_fallback.with(available_requisites: 0)
    decision = decide(build_operation(amount: 80_000, bank: "alfa"), providers: [alpha, beta, empty], policy: strict)
    expect(decision.attempts.last).to have_attributes(provider: "self", reason: reasons::NO_AVAILABLE_REQUISITES)
  end

  it "объясняет выбор перевесом над ближайшим соперником" do
    decision = decide(build_operation(amount: 10_000, bank: "sberbank"))
    expect(decision.selected_attempt.details).to match(/decisive vs beta: traffic_share \(\+[\d.]+\)/)
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
