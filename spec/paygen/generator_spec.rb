# frozen_string_literal: true

require "tmpdir"

RSpec.describe Paygen::Generator do
  let(:api) { Paygen::Analyzer.call(Paygen::SpecLoader.load(FIXTURE_SPEC)) }

  around do |example|
    Dir.mktmpdir("paygen") do |dir|
      @out = dir
      example.run
    end
  end

  def generate(**) = described_class.new(api, out_dir: @out, **).call

  it "раскладывает клиент, тесты и доки" do
    files = generate
    expect(files).to include("lib/acme_pay.rb", "lib/acme_pay/client.rb",
                             "lib/acme_pay/resources/payments.rb", "spec/payments_spec.rb", "README.md")
  end

  it "генерирует синтаксически валидный Ruby" do
    generate
    Dir.glob(File.join(@out, "**", "*.rb")).each do |file|
      expect { RubyVM::InstructionSequence.compile(File.read(file), file) }
        .not_to raise_error, "невалидный Ruby в #{file}"
    end
  end

  it "подставляет путь с интерполяцией и ключевые аргументы" do
    generate
    code = File.read(File.join(@out, "lib/acme_pay/resources/payments.rb"))
    expect(code).to include("def get_payment(payment_id, headers: {})")
    expect(code).to include('"/payments/#{payment_id}"')
    expect(code).to include("def list_payments(status: nil, limit: nil, cursor: nil, headers: {})")
  end

  it "уважает --name" do
    files = generate(gem_name: "acme")
    expect(files).to include("lib/acme.rb")
    expect(File.read(File.join(@out, "lib/acme/client.rb"))).to include("module Acme")
  end

  it "кладёт в клиент bearer-авторизацию и идемпотентность" do
    generate
    code = File.read(File.join(@out, "lib/acme_pay/client.rb"))
    expect(code).to include('"Authorization" => "Bearer #{@api_key}"')
    expect(code).to include("Idempotency-Key")
  end
end
