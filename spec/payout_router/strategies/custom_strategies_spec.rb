# frozen_string_literal: true

RSpec.describe "свои стратегии" do
  let(:alpha) { build_provider(name: "alpha", avg_latency_sec: 20, available_requisites: 10) }
  let(:beta) { build_provider(name: "beta", avg_latency_sec: 60, available_requisites: 2) }
  let(:snapshot) { build_snapshot(alpha, beta, build_fallback) }
  let(:ledger) { PayoutRouter::State::Ledger.new(snapshot) }

  def evaluate(policy, key, provider, bank: "alfa")
    candidate = PayoutRouter::Routing::Candidate.new(state: ledger.state(provider.name))
    context = PayoutRouter::Scoring::Context.new(operation: build_operation(bank: bank), ledger: ledger, now: Builders::T0)
    PayoutRouter::Strategies.instantiate(key, policy: policy, snapshot: snapshot).evaluate(candidate, context)
  end

  describe "декларативные цели" do
    let(:policy) do
      build_policy(
        "custom_goals" => {
          "fast" => { "type" => "field", "field" => "avg_latency_sec", "direction" => "lower" },
          "deal" => { "type" => "table", "scores" => { "beta" => 1.0 }, "default" => 0.1 },
          "alfa_rule" => { "type" => "bank_table", "scores" => { "alfa" => { "alpha" => 0.9 } }, "default" => 0.4 }
        },
        "goals" => { "fast" => 0.5, "deal" => 0.3, "alfa_rule" => 0.2 }
      )
    end

    it "field: нормирует поле провайдера в заданном направлении" do
      expect(evaluate(policy, "fast", alpha).score).to eq(1.0)
      expect(evaluate(policy, "fast", beta).score).to eq(0.0)
      expect(evaluate(policy, "fast", alpha).note).to include("lower is better")
    end

    it "table и bank_table: явные оценки с дефолтом" do
      expect(evaluate(policy, "deal", beta).score).to eq(1.0)
      expect(evaluate(policy, "deal", alpha).score).to be_within(0.001).of(0.1)
      expect(evaluate(policy, "alfa_rule", alpha).score).to be_within(0.001).of(0.9)
      expect(evaluate(policy, "alfa_rule", beta).score).to be_within(0.001).of(0.4)
      expect(evaluate(policy, "alfa_rule", alpha, bank: "vtb").note).to include("no rule for bank vtb")
    end

    it "участвуют в скоринге роутера и сохраняются в YAML-документе политики" do
      decision = route_all(providers: [alpha, beta, build_fallback], operations: [build_operation(bank: "alfa")],
                           policy: policy).decisions.first
      expect(decision.attempts.first.breakdown.keys).to contain_exactly("fast", "deal", "alfa_rule")
      reloaded = PayoutRouter::Inputs::PolicyLoader.from_hash(policy.to_h_document)
      expect(reloaded.custom_goals.keys).to eq(%w[fast deal alfa_rule])
    end

    it "проверяет тип и параметры" do
      expect { build_policy("custom_goals" => { "x" => { "type" => "magic" } }) }
        .to raise_error(PayoutRouter::PolicyError, /type должен быть одним из/)
      expect { build_policy("custom_goals" => { "x" => { "type" => "field", "field" => "nope" } }) }
        .to raise_error(PayoutRouter::PolicyError, /неизвестное поле провайдера/)
      expect { build_policy("custom_goals" => { "x" => { "type" => "table", "scores" => "bad" } }) }
        .to raise_error(PayoutRouter::PolicyError, /scores должен быть объектом/)
    end
  end

  describe "плагины" do
    it "подключаются из политики и регистрируются автоматически" do
      policy = PayoutRouter::Inputs::PolicyLoader.load(config_path("policies/custom_strategy.yml"))

      expect(policy.plugins.first).to end_with("requisites_headroom.rb")
      expect(PayoutRouter::Strategies::Registry.registered?("requisites_headroom")).to be(true)
      expect(PayoutRouter::Strategies::Registry.describe("requisites_headroom")).to include("плагин")
      expect(evaluate(policy, "requisites_headroom", alpha).score).to eq(1.0)
    end

    it "сообщает об отсутствующем файле плагина" do
      expect { build_policy("plugins" => ["config/plugins/missing.rb"]) }
        .to raise_error(PayoutRouter::PolicyError, /плагин .* не найден/)
    end
  end
end
