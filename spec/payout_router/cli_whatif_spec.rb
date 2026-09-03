# frozen_string_literal: true

require "fileutils"

RSpec.describe "CLI: что-если команды" do
  let(:out) { Dir.mktmpdir }

  after { FileUtils.rm_rf(out) }

  it "backtest печатает сравнение и пишет отчёт" do
    result = run_cli("backtest", "--out", out)
    expect(result.status).to eq(0)
    expect(result.stdout).to include("История: 100 заявок", "Ожидаемые одобрения")
    expect(JSON.parse(File.read(File.join(out, "backtest_report.json")))).to include("uplift_pct")
  end

  it "compare сравнивает политики" do
    result = run_cli("compare", "--out", out, "--policies", config_path("policy.yml"),
                     config_path("policies/profit_first.yml"))
    expect(result.status).to eq(0)
    expect(result.stdout).to include("balanced", "profit_first")
    expect(JSON.parse(File.read(File.join(out, "compare_report.json"))).size).to eq(2)
  end

  it "simulate даёт перцентили" do
    result = run_cli("simulate", "--out", out, "--runs", "10")
    expect(result.status).to eq(0)
    expect(result.stdout).to include("одобрено", "10 прогонов")
  end

  it "tune пишет подобранную политику, которую можно загрузить" do
    result = run_cli("tune", "--out", out, "--candidates", "4", "--synthetic", "30")
    expect(result.status).to eq(0)
    policy = PayoutRouter::Inputs::PolicyLoader.load(File.join(out, "policy_tuned.yml"))
    expect(policy.name).to eq("balanced_tuned")
    expect(policy.enabled_goals).not_to be_empty
  end

  it "explain --why-not показывает только одного провайдера" do
    result = run_cli("explain", "op_105", "--why-not", "payflow")
    expect(result.stdout).to include("payflow", "bank_not_in_list")
    expect(result.stdout).not_to include("quickpay")
  end
end
