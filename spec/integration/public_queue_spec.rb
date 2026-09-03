# frozen_string_literal: true

require "rbconfig"

RSpec.describe "публичная очередь организаторов" do
  let(:runner) { default_runner }
  let(:run) { runner.call(data_path("operations_queue_10.json")) }
  let(:reference) { PayoutRouter::Inputs::JSONFile.read(data_path("reference_decisions.json")) }
  let(:decisions) { run.serialized_decisions }
  # Обязательные поля формата организаторов (docs/tz.md, «Формат результата роутинга»).
  let(:decision_fields) { %w[operation_id selected_provider attempts simulated_result] }
  let(:attempt_fields) { %w[provider decision reason] }
  let(:results) { %w[approved rejected expired] }

  it "проходит скрипт автопроверки организаторов" do
    Dir.mktmpdir do |dir|
      path = PayoutRouter::Output::JSONWriter.write(File.join(dir, "routing_decisions.json"), decisions)
      output = IO.popen([RbConfig.ruby, File.expand_path("../../scripts/validate_10.rb", __dir__), path], &:read)
      expect(Process.last_status).to be_success
      expect(output).to include("Ошибок:   0", "Предупр.: 0")
    end
  end

  it "каждое решение несёт обязательные поля ТЗ с нужными типами" do
    expect(decisions.size).to eq(10)
    decisions.each do |decision|
      expect(decision.keys).to include(*decision_fields, "latency_sec")
      expect(decision["selected_provider"]).to be_a(String)
      expect(results).to include(decision["simulated_result"])
      expect(decision["latency_sec"]).to be_a(Integer)
    end
  end

  it "каждая попытка несёт provider/decision/reason, selected-попытка ровно одна и совпадает с selected_provider" do
    decisions.each do |decision|
      decision["attempts"].each do |attempt|
        expect(attempt.keys).to include(*attempt_fields)
        expect(attempt["decision"]).to eq("selected").or eq("skipped")
      end
      selected = decision["attempts"].select { |attempt| attempt["decision"] == "selected" }
      expect(selected.map { |attempt| attempt["provider"] }).to eq([decision["selected_provider"]])
    end
  end

  it "совпадает с эталонными кейсами, а пул допустимых равен списку организаторов" do
    reference["deterministic_cases"].each do |kase|
      expect(run.decision(kase["operation_id"]).selected_provider).to eq(kase["required_provider"])
    end
    reference["eligible_providers"].each do |id, eligible|
      # допущенные нами (не отсеянные hard-правилом) — ровно те, кого считает допустимыми скрипт организаторов
      ours = run.decision(id).attempts.reject(&:hard_skip?).map(&:provider)
      expect(ours).to match_array(eligible), "#{id}: наши допустимые #{ours}, у организаторов #{eligible}"
    end
  end

  it "фиксирует ожидаемые причины отсева" do
    reference["skip_reasons_expected"].each do |id, skips|
      skips.each do |provider, reason|
        attempt = run.decision(id).attempts.find { |a| a.provider == provider }
        expect(attempt).to have_attributes(decision: "skipped", reason: reason)
      end
    end
  end

  it "держит целевые доли: vipay 4 / payflow 3 / quickpay 3, без fallback и заявок без маршрута" do
    counts = run.report["distribution"].transform_values { |share| share["count"] }
    expect(counts).to eq("vipay" => 4, "payflow" => 3, "quickpay" => 3)
    expect(run.report["fallback_operations"]).to eq(0)
    expect(run.report["unrouted_operations"]).to eq(0)
  end

  it "отчёт: period, total_operations, distribution с count/share_pct/target_pct" do
    report = run.report
    expect(report["period"]).to eq("2026-07-30")
    expect(report["total_operations"]).to eq(10)
    report["distribution"].each_value do |share|
      expect(share).to match(hash_including("count" => Integer, "share_pct" => Numeric, "target_pct" => Numeric))
    end
    expect(report["distribution"].values.sum { |share| share["share_pct"] }).to be_within(0.2).of(100)
  end

  it "отчёт: skip_reasons, projected_daily_utilization с used/limit/utilization_pct, recommendations" do
    report = run.report
    expect(report["skip_reasons"]).to eq("bank_not_in_list" => 8, "amount_exceeds_limit" => 3,
                                         "amount_below_minimum" => 2)
    report["projected_daily_utilization"].each_value do |usage|
      expect(usage.keys).to include("used", "limit", "utilization_pct")
    end
    # 3 200 000 из снимка + 102 000 одобрено в этой сессии — состояние обновляется после каждой заявки
    expect(report["projected_daily_utilization"]["vipay"])
      .to include("used" => 3_302_000, "limit" => 5_000_000, "utilization_pct" => 66.0)
    expect(report["recommendations"]).to all(be_a(String))
    expect(report["recommendations"]).not_to be_empty
  end

  it "плотная очередь (все заявки в одну секунду) не оставляет заявок без маршрута и проходит валидатор" do
    raw = PayoutRouter::Inputs::JSONFile.read(data_path("operations_queue_10.json"))
    dense = (1..4).flat_map do |copy|
      raw.map do |op|
        op.merge("operation_id" => "#{op["operation_id"]}_#{copy}", "created_at" => "2026-07-30T09:00:00+03:00")
      end
    end
    operations = PayoutRouter::Inputs::QueueLoader.new(dense, default_time: runner.snapshot.snapshot_at).call
    result = runner.route(operations)

    expect(result.decisions.map(&:selected_provider)).to all(be_a(String))
    validation = PayoutRouter::Validation::DecisionsValidator.new(
      decisions: result.serialized_decisions, operations: operations, snapshot: runner.snapshot, policy: runner.policy
    ).call
    expect(validation.failed).to eq(0), validation.checks.select(&:fail?).map(&:message).join("; ")
    expect(result.report["fallback_operations"]).to be_positive # ёмкость внешних кончается, self-provider принимает
  end

  it "все пресеты политик прогоняют очередь без ошибок и без нарушений hard-правил" do
    Dir[config_path("policies/*.yml")].each do |policy_path|
      preset = default_runner(policy_path: policy_path)
      result = preset.call(data_path("operations_queue_10.json"))
      validation = PayoutRouter::Validation::DecisionsValidator.new(
        decisions: result.serialized_decisions, operations: result.operations, snapshot: preset.snapshot,
        policy: preset.policy, reference: reference
      ).call
      expect(validation.failed).to eq(0),
                                   "#{File.basename(policy_path)}: #{validation.checks.select(&:fail?).map(&:message)}"
    end
  end
end
