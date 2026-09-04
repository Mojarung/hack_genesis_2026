# frozen_string_literal: true

require "net/http"

RSpec.describe PayoutRouter::Server do
  let(:service) { described_class::Service.new(default_runner) }
  let(:server) { described_class.new(service, port: 0) }
  let(:thread) { Thread.new { server.start } }
  let(:operation) do
    { "operation_id" => "op_http_1", "amount" => 15_000, "bank" => "sberbank",
      "created_at" => "2026-07-30T09:05:00+03:00" }
  end

  before do
    thread
    sleep 0.05 until server.running?
  end

  after do
    server.stop
    thread.join(5)
  end

  def request(method, path, body = nil)
    uri = URI("http://127.0.0.1:#{server.port}#{path}")
    http = Net::HTTP.new(uri.host, uri.port)
    req = method == :post ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
    req.body = body if body
    req["Content-Type"] = "application/json"
    http.request(req)
  end

  it "маршрутизирует заявку" do
    response = request(:post, "/route", JSON.generate(operation))
    decision = JSON.parse(response.body)

    expect(response.code).to eq("200")
    expect(decision["operation_id"]).to eq("op_http_1")
    expect(decision["selected_provider"]).to eq("vipay")
    expect(decision["attempts"].first).to include("decision" => "selected")
  end

  it "копит состояние между запросами" do
    request(:post, "/route", JSON.generate(operation))
    state = JSON.parse(request(:get, "/state").body)

    expect(state["decisions"]).to eq(1)
    expect(state["providers"]["vipay"]["in_progress_count"]).to eq(5)
  end

  it "принимает пакет заявок и отдаёт отчёт и метрики" do
    batch = [operation, operation.merge("operation_id" => "op_http_2", "bank" => "alfa")]
    decisions = JSON.parse(request(:post, "/route", JSON.generate(batch)).body)
    expect(decisions.map { |d| d["selected_provider"] }).to eq(%w[vipay payflow])

    report = JSON.parse(request(:get, "/report").body)
    expect(report["total_operations"]).to eq(2)
    expect(report["distribution"]["vipay"]["count"]).to eq(1)

    metrics = request(:get, "/metrics").body
    expect(metrics).to include("payout_router_decisions_total{provider=\"vipay\",result=\"approved\"} 1")
    expect(metrics).to include("payout_router_provider_in_progress_count{provider=\"payflow\"}")
  end

  it "принимает состояние провайдеров вместе с заявкой и решает по нему" do
    envelope = { "operation" => operation,
                 "providers" => [{ "payment_system" => "vipay", "status" => "inactive" }] }
    decision = JSON.parse(request(:post, "/route", JSON.generate(envelope)).body)

    expect(decision["selected_provider"]).to eq("payflow")
    expect(decision["attempts"].first).to include("provider" => "vipay", "reason" => "provider_inactive")

    state = JSON.parse(request(:get, "/state").body)
    expect(state["providers"]["vipay"]["in_progress_count"]).to eq(4)
    expect(state["providers"]["payflow"]["in_progress_count"]).to eq(3)
  end

  it "живёт по часам сервиса, а не по created_at заявки" do
    request(:post, "/route", JSON.generate(operation.merge("operation_id" => "op_old",
                                                           "created_at" => "2020-01-01T00:00:00+03:00")))
    request(:post, "/route", JSON.generate(operation.merge("operation_id" => "op_new")))
    state = JSON.parse(request(:get, "/state").body)

    # Обе заявки ещё ждут ответа. Живи роутер по created_at, заявка из 2020 года считалась бы
    # отвеченной сразу же — и освободила бы ёмкость, которой на самом деле нет.
    expect(state["pending_settlements"]).to eq(2)
  end

  it "отвечает 400 на битый конверт состояния" do
    envelope = { "operation" => operation, "providers" => { "vipay" => { "in_progress_count" => -3 } } }
    response = request(:post, "/route", JSON.generate(envelope))

    expect(response.code).to eq("400")
    expect(JSON.parse(response.body)["error"]).to include("in_progress_count")
  end

  it "отвечает 400 на невалидную заявку и сбрасывает состояние по /reset" do
    bad = request(:post, "/route", JSON.generate("operation_id" => "x", "amount" => -5))
    expect(bad.code).to eq("400")
    expect(JSON.parse(bad.body)["error"]).to include("положительной")

    expect(request(:post, "/route", "{not json").code).to eq("400")
    expect(request(:get, "/route").code).to eq("405")

    request(:post, "/route", JSON.generate(operation))
    request(:post, "/reset")
    expect(JSON.parse(request(:get, "/health").body)).to include("status" => "ok", "decisions" => 0)
  end
end
