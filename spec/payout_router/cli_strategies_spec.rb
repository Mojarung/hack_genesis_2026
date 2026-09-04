# frozen_string_literal: true

RSpec.describe "CLI: справочник стратегий и цепочка" do
  it "strategies печатает правила, цели, декларативные типы и пресеты" do
    result = run_cli("strategies", "--policy", config_path("policies/custom_strategy.yml"))

    expect(result.status).to eq(0)
    expect(result.stdout).to include("Hard-правила (14)", "bank_affinity", "bank_table", "strategy_chain",
                                     "custom_strategy")
    expect(result.stdout).to include("плагины: ", "requisites_headroom.rb", "свои цели: fastest_first (field)")
  end

  it "цепочка стратегий проходит валидатор и объясняет решающий шаг" do
    runner = default_runner(policy_path: config_path("policies/strategy_chain.yml"))
    run = runner.call(data_path("operations_queue_10.json"))
    selected = run.decision("op_101").selected_attempt

    expect(selected.breakdown.keys.first).to eq("1·amount_band")
    expect(selected.details).to match(/decisive vs \w+: 1·amount_band/)
    expect(run.report["policy"]["selection"]).to start_with("chain: amount_band → turnover_min")
    reference = PayoutRouter::Inputs::JSONFile.read(data_path("reference_decisions.json"))
    reference["deterministic_cases"].each do |kase|
      expect(run.decision(kase["operation_id"]).selected_provider).to eq(kase["required_provider"])
    end
  end

  it "tune отказывается работать с цепочкой" do
    result = run_cli("tune", "--policy", config_path("policies/strategy_chain.yml"), "--candidates", "2", "--out",
                     Dir.mktmpdir)
    expect(result.status).to eq(2)
    expect(result.stderr).to include("режим chain")
  end
end
