# frozen_string_literal: true

RSpec.describe PayoutRouter::Analytics::ApprovalModel do
  # alpha × alfa: 5 наблюдений, 3 одобрено; alpha × vtb: 1 одобрено; beta × alfa: 1 таймаут.
  let(:records) do
    rows = [%w[alpha alfa approved], %w[alpha alfa rejected], %w[alpha alfa approved], %w[alpha alfa approved],
            %w[alpha alfa rejected], %w[alpha vtb approved], %w[beta alfa expired]]
    rows.each_with_index.map do |(provider, bank, status), index|
      PayoutRouter::Domain::HistoryRecord.new(operation_id: "h#{index}", amount: 100, provider: provider,
                                              bank: bank, status: status)
    end
  end
  let(:history) { PayoutRouter::Analytics::HistoryStats.new(records) }
  let(:snapshot) do
    build_snapshot(build_provider(name: "alpha", conversion_24h: 0.9),
                   build_provider(name: "beta", conversion_24h: 0.7))
  end
  let(:model) { described_class.new(history: history, snapshot: snapshot) }

  it "усаживает историю провайдера к заявленной конверсии: (approved + 10·declared) / (n + 10)" do
    estimate = model.estimate("alpha", "vtb") # по vtb одно наблюдение — меньше порога, берём провайдера
    expect(estimate).to have_attributes(source: "provider_history", samples: 6)
    expect(estimate.probability).to be_within(0.0001).of((4 + (10 * 0.9)) / 16)
  end

  it "пару провайдер × банк берёт от 5 наблюдений и усаживает к оценке провайдера" do
    provider_level = (4 + (10 * 0.9)) / 16
    estimate = model.estimate("alpha", "alfa")
    expect(estimate).to have_attributes(source: "bank_history", samples: 5)
    expect(estimate.probability).to be_within(0.0001).of((3 + (5 * provider_level)) / 10)
  end

  it "два наблюдения не дают провайдеру оценку 0.25: приор держит" do
    expect(model.estimate("beta", "alfa").probability).to be_within(0.0001).of((0 + (10 * 0.7)) / 11)
    expect(model.estimate("gamma", "alfa")).to have_attributes(source: "conversion_24h", probability: 0.0)
  end

  it "leave-one-out исключает саму запись" do
    excluded = records.first # alpha/alfa approved
    estimate = model.estimate("alpha", "alfa", exclude: excluded)
    # по паре остаётся 4 наблюдения — меньше порога; провайдер: 5 наблюдений, 3 одобрено
    expect(estimate.source).to eq("provider_history")
    expect(estimate.probability).to be_within(0.0001).of((3 + (10 * 0.9)) / 15)
    expect(history.bank_counts("alpha", "alfa", exclude: excluded)).to eq([4, 2])
  end

  it "сериализует конверсию по банкам в отчёт истории" do
    serialized = history.serialize["providers"]["alpha"]["bank_conversion"]["alfa"]
    expect(serialized).to include("operations" => 5, "approved" => 3, "conversion" => 0.6)
  end
end
