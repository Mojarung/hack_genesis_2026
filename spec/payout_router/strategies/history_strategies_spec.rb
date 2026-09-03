# frozen_string_literal: true

RSpec.describe "цели на истории и марже" do
  let(:alpha) { build_provider(name: "alpha", conversion_24h: 0.9, provider_margin_pct: 1.2, merchant_margin_pct: 1.5) }
  let(:beta) { build_provider(name: "beta", conversion_24h: 0.8, provider_margin_pct: 0.6, merchant_margin_pct: 1.5) }
  let(:snapshot) { build_snapshot(alpha, beta, build_fallback) }
  let(:ledger) { PayoutRouter::State::Ledger.new(snapshot) }
  let(:policy) { build_policy }
  let(:history) do
    records = [%w[alpha alfa approved], %w[alpha alfa rejected], %w[alpha alfa approved], %w[alpha vtb approved],
               %w[beta alfa approved], %w[beta alfa approved], %w[beta alfa approved], %w[beta alfa approved]]
    PayoutRouter::Analytics::HistoryStats.new(records.each_with_index.map do |(provider, bank, status), index|
      PayoutRouter::Domain::HistoryRecord.new(operation_id: "h#{index}", amount: 100, provider: provider,
                                              bank: bank, status: status)
    end)
  end

  def evaluate(strategy_class, provider, bank: "alfa", with_history: history)
    candidate = PayoutRouter::Routing::Candidate.new(provider: provider, state: ledger.state(provider.name))
    context = PayoutRouter::Scoring::Context.new(operation: build_operation(bank: bank), ledger: ledger, now: Builders::T0)
    strategy_class.new(policy: policy, snapshot: snapshot, history: with_history).evaluate(candidate, context)
  end

  describe PayoutRouter::Strategies::BankAffinity do
    it "оценивает сглаженную конверсию пары провайдер × банк" do
      signal = evaluate(described_class, alpha)
      expect(signal.score).to be_within(0.001).of(3.0 / 5) # (2 + 1) / (3 + 2)
      expect(signal.note).to include("alfa via alpha: 3 in history")

      expect(evaluate(described_class, beta).score).to be_within(0.001).of(5.0 / 6) # (4 + 1) / (4 + 2)
    end

    it "без наблюдений по банку берёт конверсию провайдера, без истории нейтральна" do
      signal = evaluate(described_class, alpha, bank: "gazprombank")
      expect(signal.score).to be_within(0.001).of(4.0 / 6) # (3 + 1) / (4 + 2)
      expect(signal.note).to include("no gazprombank history for alpha")

      expect(evaluate(described_class, alpha, with_history: nil).score).to eq(0.5)
      expect(evaluate(described_class, build_fallback).score).to eq(0.5)
    end
  end

  describe PayoutRouter::Strategies::ExpectedValue do
    it "нормирует ожидаемую маржу к лучшему провайдеру" do
      # alpha: 0.9 × 0.3 = 0.27; beta: 0.8 × 0.9 = 0.72 → beta = 1.0, alpha = 0.375
      expect(evaluate(described_class, beta).score).to eq(1.0)
      expect(evaluate(described_class, alpha).score).to be_within(0.001).of(0.375)
      expect(evaluate(described_class, alpha).note).to include("expected margin 0.270%")
    end
  end
end
