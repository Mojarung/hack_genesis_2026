# frozen_string_literal: true

RSpec.describe PayoutRouter::Analytics::ApprovalModel do
  let(:records) do
    [%w[alpha alfa approved], %w[alpha alfa rejected], %w[alpha vtb approved], %w[beta alfa expired]]
      .each_with_index.map do |(provider, bank, status), index|
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

  it "берёт пару провайдер × банк, когда наблюдений достаточно" do
    estimate = model.estimate("alpha", "alfa")
    expect(estimate.source).to eq("bank_history")
    expect(estimate.samples).to eq(2)
    expect(estimate.probability).to be_within(0.001).of(2.0 / 4) # (1 + 1) / (2 + 2)
  end

  it "иначе — провайдера в целом, а без истории — заявленную конверсию" do
    expect(model.estimate("alpha", "vtb")).to have_attributes(source: "provider_history", samples: 3)
    expect(model.estimate("gamma", "alfa")).to have_attributes(source: "conversion_24h", probability: 0.0)
    expect(model.estimate("beta", "vtb").probability).to be_within(0.001).of(1.0 / 3) # (0 + 1) / (1 + 2)
  end

  it "leave-one-out исключает саму запись" do
    excluded = records.first # alpha/alfa approved
    estimate = model.estimate("alpha", "alfa", exclude: excluded)
    # после исключения остаётся 1 наблюдение по паре — меньше порога, берём провайдера: 2 ops, 1 approved
    expect(estimate.source).to eq("provider_history")
    expect(estimate.probability).to be_within(0.001).of(2.0 / 4)
    expect(history.bank_conversion("alpha", "alfa", exclude: excluded)).to be_within(0.001).of(1.0 / 3)
  end

  it "сериализует конверсию по банкам в отчёт истории" do
    serialized = history.serialize["providers"]["alpha"]["bank_conversion"]["alfa"]
    expect(serialized).to include("operations" => 2, "approved" => 1)
  end
end
