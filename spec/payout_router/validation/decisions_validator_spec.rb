# frozen_string_literal: true

RSpec.describe PayoutRouter::Validation::DecisionsValidator do
  let(:runner) { default_runner }
  let(:operations) { runner.load_queue(data_path("operations_queue_10.json")) }
  let(:decisions) { runner.route(operations).serialized_decisions }
  let(:reference) { PayoutRouter::Inputs::JSONFile.read(data_path("reference_decisions.json")) }

  def validate(list)
    described_class.new(decisions: list, operations: operations, snapshot: runner.snapshot, policy: runner.policy,
                        reference: reference).call
  end

  it "принимает решения роутера по публичной очереди" do
    result = validate(decisions)
    expect(result).to be_ok
    expect(result.failed).to eq(0)
    expect(result.checks.map(&:message)).to include(a_string_matching(/op_103: эталон quickpay совпал/))
  end

  it "замечает пропущенную заявку и лишний operation_id" do
    result = validate(decisions.drop(1) + [decisions.first.merge("operation_id" => "op_999")])
    expect(result.checks.map(&:message)).to include(a_string_matching(/нет решений для: op_101/),
                                                    a_string_matching(/лишние operation_id: op_999/))
    expect(result).not_to be_ok
  end

  it "замечает недопустимого провайдера и несогласованный трейс" do
    broken = decisions.map { |d| d["operation_id"] == "op_103" ? d.merge("selected_provider" => "payflow") : d }
    messages = validate(broken).checks.select(&:fail?).map(&:message)
    expect(messages).to include(a_string_matching(/op_103: payflow НЕ допустим/), a_string_matching(/эталон quickpay/),
                                a_string_matching(/не совпадает с selected-попыткой/))
  end

  it "пустой selected_provider — ошибка, как у валидатора организаторов" do
    broken = decisions.map do |d|
      next d unless d["operation_id"] == "op_101"

      d.merge("selected_provider" => nil, "attempts" => d["attempts"].reject { |a| a["decision"] == "selected" })
    end
    result = validate(broken)
    expect(result).not_to be_ok
    failures = result.checks.select(&:fail?).map(&:message)
    expect(failures).to include(a_string_matching(/op_101: .*selected_provider пуст/))
  end

  it "проверяет структуру попыток" do
    broken = decisions.map { |d| d.merge("attempts" => [{ "provider" => "vipay", "decision" => "maybe" }]) }
    expect(validate(broken).checks.map(&:message)).to include(a_string_matching(/без reason/),
                                                              a_string_matching(%r{selected/skipped}))
  end

  it "требует массив" do
    expect { validate({}) }.to raise_error(PayoutRouter::InputError, /массив/)
  end
end
