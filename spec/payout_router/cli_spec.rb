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

  it "путь сдачи (как rake submit): route --suffix _test, затем validate по той же очереди" do
    test_queue = File.join(out, "operations_queue_test.json")
    FileUtils.cp(queue, test_queue)
    routed = run_cli("route", "--queue", test_queue, "--out", out, "--suffix", "_test", "--quiet")
    expect(routed.status).to eq(0)
    expect(File).to exist(File.join(out, "routing_decisions_test.json"))
    expect(File).to exist(File.join(out, "routing_report_test.json"))

    validated = run_cli("validate", File.join(out, "routing_decisions_test.json"), "--queue", test_queue)
    expect(validated.status).to eq(0)
    expect(validated.stdout).to include("ошибок 0")
  end

  it "validate падает с кодом 1, если решение пустое" do
    run_cli("route", "--out", out, "--quiet")
    path = File.join(out, "routing_decisions.json")
    broken = JSON.parse(File.read(path)).map { |d| d.merge("selected_provider" => nil, "attempts" => []) }
    File.write(path, JSON.generate(broken))

    result = run_cli("validate", path)
    expect(result.status).to eq(1)
    expect(result.stdout).to include("selected_provider пуст")
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

  # Подсказка про карантин относится к отдельной заявке. На «нет файла» она уводит по ложному
  # следу: --on-invalid skip там не поможет ни с очередью, ни со снимком провайдеров.
  it "не советует --on-invalid skip там, где он не поможет" do
    missing_queue = run_cli("route", "--out", out, "--queue", "missing.json")
    expect(missing_queue.stderr).not_to include("--on-invalid skip")

    missing_providers = run_cli("route", "--out", out, "--queue", queue, "--providers", "missing.json")
    expect(missing_providers.status).to eq(2)
    expect(missing_providers.stderr).to include("ошибка: файл не найден")
    expect(missing_providers.stderr).not_to include("--on-invalid skip")
  end

  it "битая заявка: по умолчанию останавливает прогон с подсказкой, с --on-invalid skip уходит в карантин" do
    broken = File.join(out, "broken.json")
    rows = JSON.parse(File.read(queue))
    rows[2]["amount"] = "много"
    File.write(broken, JSON.generate(rows))

    strict = run_cli("route", "--out", out, "--queue", broken, "--quiet")
    expect(strict.status).to eq(2)
    expect(strict.stderr).to include("amount должно быть числом", "--on-invalid skip")

    lenient = run_cli("route", "--out", out, "--queue", broken, "--on-invalid", "skip", "--quiet")
    expect(lenient.status).to eq(0)
    # Предупреждение идёт в stderr: под --quiet Thor глушит обычный вывод, а пропуск заявки
    # обязан быть видно — иначе неполный файл решений выглядит как полный.
    expect(lenient.stderr).to include("op_103 не разобрана и пропущена")
    expect(JSON.parse(File.read(File.join(out, "routing_decisions.json"))).size).to eq(9)
  end

  it "validate читает очередь как route: без флага падает, с --on-invalid skip проверяет уцелевшие" do
    broken = File.join(out, "broken_queue.json")
    rows = JSON.parse(File.read(queue))
    rows[2]["amount"] = "много"
    File.write(broken, JSON.generate(rows))
    run_cli("route", "--out", out, "--queue", broken, "--on-invalid", "skip", "--quiet")
    decisions = File.join(out, "routing_decisions.json")

    strict = run_cli("validate", decisions, "--queue", broken)
    expect(strict.status).to eq(2)
    expect(strict.stderr).to include("amount должно быть числом")

    lenient = run_cli("validate", decisions, "--queue", broken, "--on-invalid", "skip")
    expect(lenient.status).to eq(0)
    expect(lenient.stdout).to include("все 9 заявок из очереди покрыты",
                                      "в карантине 1 заявок, решений по ним нет: op_103",
                                      "ошибок 0, предупреждений 1")
  end

  it "сообщает об ошибке политики" do
    policy = File.join(out, "policy.yml")
    File.write(policy, "goals:\n  nope: 1\n")
    result = run_cli("route", "--out", out, "--policy", policy)
    expect(result.status).to eq(2)
    expect(result.stderr).to include("неизвестная цель «nope»")
  end
end
