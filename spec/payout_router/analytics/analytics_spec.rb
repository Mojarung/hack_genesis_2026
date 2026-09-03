# frozen_string_literal: true

RSpec.describe "аналитика" do
  describe PayoutRouter::Analytics::HistoryStats do
    subject(:stats) { described_class.new(PayoutRouter::Inputs::HistoryLoader.load(data_path("operations_history.csv"))) }

    it "считает доли, конверсию и таймауты по провайдерам" do
      expect(stats.total_operations).to eq(100)
      expect(stats.providers).to eq(%w[payflow quickpay vipay])
      expect(stats.count_share_pct("vipay")).to eq(41.0)
      expect(stats.conversion("payflow")).to be_within(0.001).of(9.0 / 19)
      expect(stats.expired_share("payflow")).to be_within(0.001).of(7.0 / 10)
    end

    it "сериализуется для отчёта" do
      serialized = stats.serialize
      expect(serialized["providers"]["vipay"]).to include("operations" => 41, "conversion" => 0.78)
      expect(serialized["banks"].keys.first).to be_a(String)
    end

    it "пустая история не ломает расчёты" do
      empty = described_class.new([])
      expect(empty).to be_empty
      expect(empty.conversion("vipay")).to be_nil
      expect(empty.count_share_pct("vipay")).to eq(0.0)
    end
  end

  describe PayoutRouter::Analytics::ReportBuilder do
    let(:run) { default_runner.call(data_path("operations_queue_10.json")) }
    let(:report) { run.report }

    it "содержит обязательные разделы формата организаторов" do
      expect(report.keys).to include("period", "total_operations", "distribution", "skip_reasons",
                                     "projected_daily_utilization", "recommendations")
      expect(report["period"]).to eq("2026-07-30")
      expect(report["total_operations"]).to eq(10)
      expect(report["distribution"]["vipay"]).to include("count", "share_pct", "target_pct")
      expect(report["projected_daily_utilization"]["vipay"]).to include("used", "limit", "utilization_pct")
    end

    it "распределение сходится к 100% и отклонения считаются от цели" do
      shares = report["distribution"].values.sum { |share| share["share_pct"] }
      expect(shares).to be_within(0.2).of(100)
      expect(report["distribution"]["vipay"]["deviation_pp"]).to eq(report["distribution"]["vipay"]["share_pct"] - 40)
    end

    it "показывает достижимость целей и причины блокировок" do
      vipay = report["target_attainability"]["vipay"]
      expect(vipay["eligible"] + vipay["blocked_by"].values.sum).to eq(10)
      expect(vipay["blocked_banks"]).to include("alfa")
    end

    it "диагностирует, какие цели различали кандидатов, и предлагает снять мёртвый вес" do
      activity = report["goal_activity"]
      expect(activity["contested_operations"]).to be_between(1, 10)
      expect(activity["goals"].keys).to include("traffic_share", "turnover_min")
      expect(activity["goals"]["turnover_min"]).to include("weight" => 0.05, "discriminating_operations" => 0)
      expect(activity["goals"]["load"]["discriminating_operations"]).to be_positive

      dead = report["recommendation_details"].find do |d|
        d["rule"] == "dead_goal" && d["parameter"] == "goals.turnover_min"
      end
      expect(dead).to include("current" => 0.05, "suggested" => 0)
    end

    it "даёт рекомендации с конкретным параметром" do
      details = report["recommendation_details"]
      expect(details).not_to be_empty
      expect(details.first).to include("severity", "rule", "parameter", "message")
      expect(report["recommendations"]).to all(be_a(String))
      expect(report["recommendation_details"].map do |d|
        d["rule"]
      end).to include("daily_limit_pressure", "conversion_drift")
    end

    it "сравнивает заявленную конверсию с наблюдаемой" do
      expect(report["history_analysis"]["conversion_drift"]["payflow"]).to include("reported" => 0.91)
    end
  end

  describe PayoutRouter::Analytics::Recommendations::Engine do
    let(:alpha) do
      build_provider(name: "alpha", traffic_percentage: 70, banks: %w[vtb], daily_amount_limit: 100_000,
                     daily_approved_amount: 80_000, requests_per_minute_limit: 1)
    end
    let(:beta) { build_provider(name: "beta", traffic_percentage: 30, conversion_24h: 0.6, limit_amount_max: 20_000) }
    let(:policy) do
      build_policy("providers" => { "alpha" => { "requests_per_minute_limit" => 1, "daily_turnover_min" => 500_000 } })
    end
    let(:operations) do
      [build_operation(id: "a", bank: "alfa", at: Builders::T0),
       build_operation(id: "b", bank: "alfa", at: Builders::T0 + 10),
       build_operation(id: "c", bank: "vtb", at: Builders::T0 + 20),
       build_operation(id: "d", bank: "vtb", at: Builders::T0 + 30),
       build_operation(id: "e", bank: "vtb", amount: 150_000, at: Builders::T0 + 40)]
    end
    let(:rules) do
      result = route_all(providers: [alpha, beta, build_fallback], operations: operations, policy: policy)
      snapshot = policy.apply(build_snapshot(alpha, beta, build_fallback))
      stats = PayoutRouter::Analytics::RoutingStats.new(decisions: result.decisions, ledger: result.ledger,
                                                        snapshot: snapshot)
      context = PayoutRouter::Analytics::Recommendations::Context.new(stats: stats, history: PayoutRouter::Analytics::HistoryStats.new([]),
                                                                      snapshot: snapshot, policy: policy)
      described_class.new.call(context).group_by(&:rule)
    end

    it "замечает недостижимую долю из-за фильтра банков и предлагает банки" do
      shortfall = rules.fetch("share_shortfall").find { |r| r.provider == "alpha" }
      expect(shortfall.parameter).to eq("banks")
      expect(shortfall.suggested).to include("alfa")
      expect(shortfall.message).to include("недостижима")
    end

    it "замечает уход заявок на fallback и разрыв по сумме" do
      expect(rules.fetch("fallback_usage").first.message).to include("self-provider self")
      gap = rules.fetch("amount_coverage_gap").first
      expect(gap.parameter).to eq("limit_amount_max")
      expect(gap.suggested).to be >= 150_000
    end

    it "замечает лимит интенсивности и невыполненное обязательство по обороту" do
      expect(rules.fetch("rate_limit_hits").first).to have_attributes(provider: "alpha", suggested: 6)
      expect(rules.fetch("turnover_min_unmet").first.message).to include("не менее 500 000 ₽")
    end

    it "сортирует по важности" do
      severities = rules.values.flatten.sort_by(&:rank).map(&:severity)
      expect(severities).to eq(severities.sort_by { |s|
        PayoutRouter::Analytics::Recommendations::Recommendation::SEVERITIES.index(s)
      })
    end
  end
end
