# frozen_string_literal: true

require "fileutils"

RSpec.describe PayoutRouter::CLI do
  let(:out) { Dir.mktmpdir }
  let(:queue) { data_path("operations_queue_10.json") }

  after { FileUtils.rm_rf(out) }

  it "route пишет решения и отчёт, печатает сводку" do
    result = run_cli("route", "--out", out, "--queue", queue)

    expect(result.status).to eq(0)
    expect(result.stdout).to include("Заявок: 10", "Рекомендации:")
    decisions = JSON.parse(File.read(File.join(out, "routing_decisions.json")))
    report = JSON.parse(File.read(File.join(out, "routing_report.json")))
    expect(decisions.size).to eq(10)
    expect(report["total_operations"]).to eq(10)
  end

  it "route с суффиксом и режимом conversion" do
    result = run_cli("route", "--out", out, "--suffix", "_test", "--simulation", "conversion", "--seed", "3", "--quiet")

    expect(result.status).to eq(0)
    expect(File).to exist(File.join(out, "routing_decisions_test.json"))
    report = JSON.parse(File.read(File.join(out, "routing_report_test.json")))
    expect(report["simulation"]).to eq("mode" => "conversion", "seed" => 3)
  end

  it "explain разбирает заявку" do
    result = run_cli("explain", "op_103")
    expect(result.stdout).to include("op_103", "amount_exceeds_limit", "=> quickpay: approved")
  end

  it "validate проверяет файл решений с эталоном" do
    run_cli("route", "--out", out, "--quiet")
    result = run_cli("validate", File.join(out, "routing_decisions.json"), "--reference",
                     data_path("reference_decisions.json"))

    expect(result.status).to eq(0)
    expect(result.stdout).to include("ошибок 0")
  end

  it "history печатает таблицу" do
    result = run_cli("history")
    expect(result.stdout).to include("payflow", "банки:")
  end

  it "сообщает о некорректных входных данных с кодом 2" do
    result = run_cli("route", "--out", out, "--queue", "missing.json")
    expect(result.status).to eq(2)
    expect(result.stderr).to include("ошибка: файл не найден")
  end

  it "сообщает об ошибке политики" do
    policy = File.join(out, "policy.yml")
    File.write(policy, "goals:\n  nope: 1\n")
    result = run_cli("route", "--out", out, "--policy", policy)
    expect(result.status).to eq(2)
    expect(result.stderr).to include("неизвестная цель «nope»")
  end
end
