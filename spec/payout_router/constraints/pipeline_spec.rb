# frozen_string_literal: true

RSpec.describe PayoutRouter::Constraints::Pipeline do
  subject(:pipeline) { described_class.new(PayoutRouter::Constraints::Registry.keys) }

  let(:reasons) { PayoutRouter::Routing::Reasons }

  def evaluate(provider, operation = build_operation, ledger: nil)
    pipeline.evaluate(build_candidate(provider, ledger), operation, operation.created_at)
  end

  it "допускает провайдера, у которого всё в порядке" do
    expect(evaluate(build_provider)).to be_eligible
  end

  {
    "provider_inactive" => [{ status: "paused" }, {}, "status=paused"],
    "traffic_disabled" => [{ traffic_percentage: 0 }, {}, "traffic_percentage=0"],
    "currency_mismatch" => [{ currency: "RUB" }, { currency: "USD" }, "USD != provider currency RUB"],
    "amount_below_minimum" => [{ limit_amount_min: 1_000 }, { amount: 800 }, "800 < limit_amount_min 1000"],
    "amount_exceeds_limit" => [{ limit_amount_max: 50_000 }, { amount: 150_000 }, "150000 > limit_amount_max 50000"],
    "daily_limit_exceeded" => [{ daily_amount_limit: 100_000, daily_approved_amount: 95_000 }, {},
                               "95000 + 10000 > daily_amount_limit 100000"],
    "in_progress_count_limit_reached" => [{ in_progress_count_limit: 2, in_progress_count: 2 }, {},
                                          "2 + 1 > in_progress_count_limit 2"],
    "in_progress_amount_limit_exceeded" => [{ in_progress_amount_limit: 15_000, in_progress_amount: 9_000 }, {},
                                            "9000 + 10000 >"],
    "no_available_requisites" => [{ available_requisites: 0 }, {}, "available_requisites=0"],
    "negative_margin" => [{ provider_margin_pct: 2.0, merchant_margin_pct: 1.5 }, {}, "2.0 > merchant_margin_pct 1.5"],
    "bank_not_in_list" => [{ banks: %w[vtb] }, { bank: "alfa" }, "alfa not in banks [vtb]"],
    "bank_excluded" => [{ banks: %w[alfa], exclude_banks: true }, { bank: "alfa" }, "alfa in exclude_banks"],
    "bank_unknown" => [{ banks: %w[vtb] }, { bank: nil }, "bank is missing"],
    "daily_turnover_max_exceeded" => [{ daily_turnover_max: 15_000, daily_approved_amount: 10_000 }, {},
                                      "10000 + 10000 > daily_turnover_max 15000"]
  }.each do |reason, (provider_attrs, operation_attrs, details)|
    it "отсеивает с причиной #{reason}" do
      evaluation = evaluate(build_provider(**provider_attrs), build_operation(**operation_attrs))

      expect(evaluation).not_to be_eligible
      expect(evaluation.reason).to eq(reason)
      expect(evaluation.details).to include(details)
    end
  end

  it "отсеивает по интенсивности, глядя на отправки за последнюю минуту" do
    provider = build_provider(requests_per_minute_limit: 2)
    ledger = PayoutRouter::State::Ledger.new(build_snapshot(provider))
    outcome = PayoutRouter::Simulation::Outcome.new(result: "approved", latency_sec: 5)
    ledger.dispatch!(ledger.state("alpha"), build_operation, outcome, Builders::T0)
    ledger.dispatch!(ledger.state("alpha"), build_operation, outcome, Builders::T0 + 10)

    within_minute = evaluate(provider, build_operation(at: Builders::T0 + 30), ledger: ledger)
    expect(within_minute.reason).to eq(reasons::RATE_LIMIT_EXCEEDED)
    expect(within_minute.details).to include("2 requests in last 60s >= requests_per_minute_limit 2")

    expect(evaluate(provider, build_operation(at: Builders::T0 + 120), ledger: ledger)).to be_eligible
  end

  it "собирает все нарушения, а не только первое" do
    evaluation = evaluate(build_provider(status: "paused", banks: %w[vtb]), build_operation(bank: "alfa"))
    expect(evaluation.reasons).to eq([reasons::PROVIDER_INACTIVE, reasons::BANK_NOT_IN_LIST])
  end

  it "не применяет traffic_enabled к fallback-провайдеру и пропускает null-лимиты" do
    expect(evaluate(build_fallback, build_operation(amount: 5_000_000, bank: "any"))).to be_eligible
  end

  it "ругается на неизвестное правило" do
    expect { described_class.new(["nope"]) }.to raise_error(PayoutRouter::PolicyError, /nope/)
  end
end
