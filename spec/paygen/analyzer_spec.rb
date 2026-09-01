# frozen_string_literal: true

RSpec.describe Paygen::Analyzer do
  subject(:api) { described_class.call(Paygen::SpecLoader.load(FIXTURE_SPEC)) }

  it "подставляет дефолты серверных переменных в base_url" do
    expect(api.base_url).to eq("https://api.sandbox.acmepay.com/v1")
  end

  it "распознаёт bearer-авторизацию" do
    expect(api.auth.kind).to eq(:bearer)
  end

  it "группирует операции по тегам" do
    expect(api.resources.map(&:name)).to contain_exactly("payments", "refunds")
    expect(api.operations.size).to eq(5)
  end

  it "наследует параметры уровня path-item" do
    op = api.operations.find { |o| o.method_name == "get_payment" }
    expect(op.path_params.map(&:name)).to eq(["payment_id"])
    expect(op.path_template).to eq('/payments/#{payment_id}')
  end

  it "видит тело запроса и его схему" do
    op = api.operations.find { |o| o.method_name == "create_payment" }
    expect(op.body.schema_name).to eq("PaymentRequest")
    expect(op.body).to be_required
    expect(op.body.properties.select(&:required?).map(&:name)).to contain_exactly("amount", "payment_method")
  end

  it "переносит query-параметры с enum и дефолтами" do
    op = api.operations.find { |o| o.method_name == "list_payments" }
    status = op.query_params.find { |p| p.name == "status" }
    expect(status.enum).to include("captured")
    expect(op.query_params.map(&:name)).to contain_exactly("status", "limit", "cursor")
  end

  it "позволяет переопределить base_url" do
    api = described_class.call(Paygen::SpecLoader.load(FIXTURE_SPEC), base_url: "http://localhost:4010")
    expect(api.base_url).to eq("http://localhost:4010")
  end
end
