# frozen_string_literal: true

RSpec.describe "цели на истории и марже" do
  let(:alpha) { build_provider(name: "alpha", conversion_24h: 0.9, provider_margin_pct: 1.2, merchant_margin_pct: 1.5) }
  let(:beta) { build_provider(name: "beta", conversion_24h: 0.8, provider_margin_pct: 0.6, merchant_margin_pct: 1.5) }
  let(:snapshot) { build_snapshot(alpha, beta, build_fallback) }
  let(:ledger) { PayoutRouter::State::Ledger.new(snapshot) }
  let(:policy) { build_policy }
  # alpha: 4 наблюдения, 3 одобрено (alfa 3 — меньше порога 5); beta × alfa: 5 одобрено из 5.
  # Откалиброванные конверсии (посчитаны вручную):
  #   alpha (3 + 10 × 0.9) / 14 = 0.8571, beta (5 + 10 × 0.8) / 15 = 0.8667.
  let(:history) do
    records = [%w[alpha alfa approved], %w[alpha alfa rejected], %w[alpha alfa approved], %w[alpha vtb approved],
               %w[beta alfa approved], %w[beta alfa approved], %w[beta alfa approved], %w[beta alfa approved],
               %w[beta alfa approved]]
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
    it "оценивает пару провайдер × банк, усаженную к конверсии провайдера" do
      signal = evaluate(described_class, beta)
      expect(signal.score).to be_within(0.0001).of(0.9333) # (5 + 5 × 0.8667) / 10
      expect(signal.note).to include("alfa via beta: 5 in history")
    end

    it "при малом числе наблюдений по банку берёт провайдера, без истории нейтральна" do
      signal = evaluate(described_class, alpha)
      expect(signal.score).to be_within(0.0001).of(0.8571)
      expect(signal.note).to include("alfa via alpha: 3 in history (< 5), using provider overall: 4 ops")

      expect(evaluate(described_class, alpha,
                      bank: "gazprombank").note).to include("gazprombank via alpha: 0 in history")
      expect(evaluate(described_class, alpha, with_history: nil).score).to eq(0.5)
      expect(evaluate(described_class, build_fallback).score).to eq(0.5)
    end
  end

  describe PayoutRouter::Strategies::Conversion do
    it "калибрует заявленную конверсию по истории, без истории берёт заявленную" do
      signal = evaluate(described_class, alpha)
      expect(signal.score).to be_within(0.0001).of(0.8571)
      expect(signal.note).to include("conversion_24h 0.9, history 4 ops → calibrated 0.857")
      expect(evaluate(described_class, alpha, with_history: nil).score).to eq(0.9)
    end
  end

  describe PayoutRouter::Strategies::ExpectedValue do
    it "нормирует ожидаемую маржу к лучшему провайдеру" do
      # без истории: alpha 0.9 × 0.3 = 0.27; beta 0.8 × 0.9 = 0.72 → beta = 1.0, alpha = 0.375
      expect(evaluate(described_class, beta, with_history: nil).score).to eq(1.0)
      expect(evaluate(described_class, alpha, with_history: nil).score).to be_within(0.001).of(0.375)
      expect(evaluate(described_class, alpha, with_history: nil).note).to include("expected margin 0.270%")
    end

    it "с историей использует откалиброванную конверсию" do
      # alpha 0.8571 × 0.3 = 0.2571; beta 0.8667 × 0.9 = 0.78 → alpha = 0.2571 / 0.78
      expect(evaluate(described_class, alpha).score).to be_within(0.001).of(0.3297)
      expect(evaluate(described_class, alpha).note).to include("conversion 0.857")
    end
  end
end
