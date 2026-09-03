# frozen_string_literal: true

require "rbconfig"

RSpec.describe "публичная очередь организаторов" do
  let(:runner) { default_runner }
  let(:run) { runner.call(data_path("operations_queue_10.json")) }
  let(:reference) { PayoutRouter::Inputs::JSONFile.read(data_path("reference_decisions.json")) }

  it "проходит скрипт автопроверки организаторов" do
    Dir.mktmpdir do |dir|
      path = PayoutRouter::Output::JSONWriter.write(File.join(dir, "routing_decisions.json"), run.serialized_decisions)
      output = IO.popen([RbConfig.ruby, File.expand_path("../../scripts/validate_10.rb", __dir__), path], &:read)
      expect(Process.last_status).to be_success
      expect(output).to include("Ошибок:   0")
    end
  end

  it "совпадает с эталонными кейсами и списками допустимых" do
    reference["deterministic_cases"].each do |kase|
      expect(run.decision(kase["operation_id"]).selected_provider).to eq(kase["required_provider"])
    end
    reference["eligible_providers"].each do |id, eligible|
      expect(eligible).to include(run.decision(id).selected_provider)
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

  it "держит целевые доли: vipay 40% при цели 40" do
    expect(run.report["distribution"]["vipay"]["count"]).to eq(4)
    expect(run.report["fallback_operations"]).to eq(0)
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
