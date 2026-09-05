# frozen_string_literal: true

RSpec.describe "перебор конфигураций политики" do
  let(:alpha) { build_provider(name: "alpha", priority: 1, conversion_24h: 0.80, traffic_percentage: 60) }
  let(:beta) { build_provider(name: "beta", priority: 2, conversion_24h: 0.95, traffic_percentage: 40) }
  let(:snapshot) { build_snapshot(alpha, beta, build_fallback) }
  let(:policy) { build_policy("goals" => { "traffic_share" => 0.6, "conversion" => 0.4 }) }
  let(:operations) do
    Array.new(20) { |index| build_operation(id: "op_#{index}", amount: 10_000, at: Builders::T0 + (index * 60)) }
  end
  let(:battery) do
    PayoutRouter::Search::Battery.new(base_snapshot: snapshot, history: nil,
                                      queues: { "q" => operations })
  end

  describe PayoutRouter::Search::Battery do
    it "меряет политику на батарее: отклонение от долей, конверсия, fallback и маршрутизируемость" do
      metrics = battery.call(policy)

      expect(metrics.deviation_pp).to be >= 0.0
      expect(metrics.conversion).to be_between(0.0, 1.0)
      expect(metrics.unrouted_rate).to eq(0.0)
      expect(metrics.backtest_uplift_pct).to eq(0.0) # без истории бэктест не считается
    end

    it "одна и та же политика на той же батарее даёт тот же результат" do
      first = battery.call(policy)

      expect(battery.call(policy)).to eq(first)
    end
  end

  describe PayoutRouter::Search::Metrics do
    let(:better) do
      described_class.new(deviation_pp: 10.0, worst_deviation_pp: 10.0, conversion: 0.9, margin_per_op: 1.0,
                          fallback_rate: 0.0, unrouted_rate: 0.0, backtest_uplift_pct: 0.0)
    end
    let(:worse) { better.with(deviation_pp: 20.0, conversion: 0.8) }

    it "доминирование: лучше по обеим целям — доминирует, лучше по одной ценой другой — нет" do
      expect(better.dominates?(worse)).to be(true)
      expect(worse.dominates?(better)).to be(false)
      expect(better.dominates?(better.with(deviation_pp: 5.0, conversion: 0.95))).to be(false)
    end

    it "различия внутри допуска не считаются улучшением" do
      expect(better.with(deviation_pp: 9.999).dominates?(better)).to be(false)
    end
  end

  describe PayoutRouter::Search::Front do
    let(:front) { described_class.new }

    def point(deviation, conversion)
      PayoutRouter::Search::Candidate.new(
        origin: "x", structural: "s", goals: {},
        metrics: PayoutRouter::Search::Metrics.new(deviation_pp: deviation, worst_deviation_pp: deviation,
                                                   conversion: conversion, margin_per_op: 0.0, fallback_rate: 0.0,
                                                   unrouted_rate: 0.0, backtest_uplift_pct: 0.0)
      )
    end

    it "принимает недоминируемые точки и отвергает дубли и худшие" do
      expect(front.add?(point(10.0, 0.80))).to be(true)
      expect(front.add?(point(20.0, 0.90))).to be(true)
      expect(front.add?(point(30.0, 0.85))).to be(false) # хуже второй по обеим целям
      expect(front.add?(point(10.0, 0.80))).to be(false) # дубль
    end

    it "новая точка выбивает все, которые она доминирует" do
      [point(10.0, 0.80), point(20.0, 0.90)].each { |item| front.add?(item) }

      expect(front.add?(point(5.0, 0.95))).to be(true)
      expect(front.size).to eq(1)
      expect(front.candidates.first.metrics.deviation_pp).to eq(5.0)
    end
  end

  describe PayoutRouter::Search::Space do
    it "структурная сетка перебирает нормировку, трактовку целей и правило дневного лимита" do
      labels = described_class.structural(policy).map(&:first)

      expect(labels.size).to eq(12)
      expect(labels).to include("pool/absolute/daily_limit", "damped/attainable/daily_limit_reserved")
    end

    it "подменяет правило дневного лимита, не трогая остальные" do
      swapped = described_class.swap_limit(%w[provider_active daily_limit bank_filter], "daily_limit_reserved")

      expect(swapped).to eq(%w[provider_active daily_limit_reserved bank_filter])
    end

    it "перебирает базу, одиночные цели, аблации, сетку и случайные точки" do
      space = described_class.new(policy: policy, random_samples: 3, grid_goals: %w[traffic_share conversion])
      origins = space.each.map(&:first)

      expect(origins.first).to eq("base")
      expect(origins).to include("only:traffic_share", "base-conversion", "grid", "random#0")
      expect(space.each.map(&:last)).to all(satisfy { |goals| goals.values.sum.positive? })
    end
  end

  describe PayoutRouter::Search::Engine do
    it "возвращает базу, границу Парето и лидеров по каждой метрике" do
      outcome = described_class.new(battery: battery, policy: policy, random_samples: 2,
                                    grid_goals: %w[traffic_share conversion], shard: 0, shards: 12).call

      expect(outcome.evaluations).to be > 10
      expect(outcome.base.origin).to eq("base")
      expect(outcome.front).to all(be_a(PayoutRouter::Search::Candidate))
      expect(outcome.bests.keys).to include("min_deviation", "max_conversion", "min_scalar")
      expect(outcome.structural.keys).to eq(["pool/absolute/daily_limit"])
    end

    it "шарды покрывают все структурные варианты и не пересекаются" do
      labels = (0..11).flat_map do |shard|
        described_class.new(battery: battery, policy: policy, random_samples: 0,
                            grid_goals: %w[traffic_share], shard: shard, shards: 12).call.structural.keys
      end

      expect(labels.uniq.size).to eq(12)
      expect(labels.size).to eq(12)
    end
  end
end
