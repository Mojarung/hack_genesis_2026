# frozen_string_literal: true

require "tempfile"

RSpec.describe Paygen::SpecLoader do
  subject(:doc) { described_class.load(FIXTURE_SPEC) }

  it "разворачивает локальные $ref" do
    schema = doc.dig("paths", "/payments", "post", "requestBody", "content", "application/json", "schema")
    expect(schema["x-ref-name"]).to eq("PaymentRequest")
    expect(schema.dig("properties", "amount", "properties", "currency", "type")).to eq("string")
  end

  it "обрывает циклические ссылки, а не уходит в бесконечность" do
    payment = doc.dig("components", "schemas", "Payment")
    # Payment -> refunds[] -> Refund -> payment -> Payment -> refunds[] : здесь обрыв
    nested = payment.dig("properties", "refunds", "items", "properties", "payment",
                         "properties", "refunds", "items")
    expect(nested).to include("x-cycle" => true, "x-ref-name" => "Refund")
  end

  it "падает с понятной ошибкой на отсутствующем файле" do
    expect { described_class.load("nope.yaml") }.to raise_error(Paygen::SpecError, /не найден/)
  end

  it "падает, если это не OpenAPI" do
    Tempfile.create(["x", ".yaml"]) do |f|
      f.write("foo: bar\n")
      f.flush
      expect { described_class.load(f.path) }.to raise_error(Paygen::SpecError, /OpenAPI/)
    end
  end
end
