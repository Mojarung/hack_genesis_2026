# frozen_string_literal: true

RSpec.describe "калибровка по истории" do
  subject(:stats) do
    PayoutRouter::Analytics::HistoryStats.new(PayoutRouter::Inputs::HistoryLoader.load(data_path("operations_history.csv")))
  end

  it "считает 95% интервал Уилсона для конверсии провайдера" do
    expect(stats.conversion_interval("payflow")).to eq([0.273, 0.683])
    expect(stats.conversion_interval("vipay")).to eq([0.633, 0.880])
    expect(stats.conversion_interval("nobody")).to be_nil
  end

  it "считает конверсию по размеру чека" do
    buckets = stats.amount_buckets
    expect(buckets["1001-50000"]).to include("operations" => 74)
    expect(buckets["50001-100000"]["conversion"]).to be_within(0.001).of(0.810)
    expect(buckets[">100000"]).to include("operations" => 5, "conversion" => 0.4)
    expect(stats.serialize["amount_buckets"].keys).to eq(PayoutRouter::Analytics::HistoryStats::AMOUNT_BUCKETS.map(&:first))
  end

  it "дрейф конверсии считается значимым только вне интервала" do
    report = default_runner.call(data_path("operations_queue_10.json")).report
    drift = report["history_analysis"]["conversion_drift"]

    expect(drift["payflow"]).to include("significant" => true, "interval_95" => [0.273, 0.683])
    expect(drift["vipay"]["significant"]).to be(false)
    rules = report["recommendation_details"].select { |rec| rec["rule"] == "conversion_drift" }
    expect(rules.map { |rec| rec["provider"] }).to eq(["payflow"])
    expect(rules.first["message"]).to include("вне 95% интервала")
  end
end
