# frozen_string_literal: true

RSpec.describe "загрузчики входных данных" do
  describe PayoutRouter::Inputs::ProvidersLoader do
    it "читает providers.json организаторов" do
      snapshot = described_class.load(data_path("providers.json"))

      expect(snapshot.names).to eq(%w[vipay payflow quickpay spacepayments])
      expect(snapshot.snapshot_at).to eq(Time.iso8601("2026-07-30T09:00:00+03:00"))
      expect(snapshot.provider("vipay").banks).to eq(%w[sberbank tinkoff vtb])
      expect(snapshot.provider("spacepayments").limit_amount_max).to be_nil
    end

    it "валюту провайдера берёт из поля currency, иначе из имени шлюза" do
      expect(described_class.load(data_path("providers.json")).provider("vipay").currency).to eq("RUB")

      raw = { "gateway" => "USD_CARD", "providers" => [{ "payment_system" => "x", "status" => "active" },
                                                       { "payment_system" => "y", "status" => "active",
                                                         "currency" => "eur" }] }
      snapshot = described_class.new(raw).call
      expect(snapshot.provider("x").currency).to eq("USD")
      expect(snapshot.provider("y").currency).to eq("EUR")
      expect(described_class.new({ "providers" => [] }).call.providers).to be_empty
    end

    it "требует массив providers" do
      expect { described_class.new({ "providers" => "x" }).call }
        .to raise_error(PayoutRouter::InputError, /массивом providers/)
    end

    it "проверяет типы полей с указанием провайдера" do
      raw = { "providers" => [{ "payment_system" => "vipay", "status" => "active", "conversion_24h" => "high" }] }
      expect { described_class.new(raw).call }.to raise_error(PayoutRouter::InputError, /вайдер vipay.*conversion_24h/)
    end

    it "не пропускает диапазон суммы с min > max" do
      raw = { "providers" => [{ "payment_system" => "x", "status" => "active", "limit_amount_min" => 10,
                                "limit_amount_max" => 5 }] }
      expect { described_class.new(raw).call }.to raise_error(PayoutRouter::InputError, /limit_amount_min 10 больше/)
    end

    it "не пропускает дубликаты провайдеров" do
      raw = { "providers" => [{ "payment_system" => "x", "status" => "active" },
                              { "payment_system" => "x", "status" => "active" }] }
      expect { described_class.new(raw).call }.to raise_error(PayoutRouter::InputError, /повторяются: x/)
    end

    it "сообщает о невалидном JSON и отсутствующем файле" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "broken.json")
        File.write(path, "{ not json")
        expect { described_class.load(path) }.to raise_error(PayoutRouter::InputError, /невалидный JSON/)
      end
      expect { described_class.load("nope.json") }.to raise_error(PayoutRouter::InputError, /не найден/)
    end
  end

  describe PayoutRouter::Inputs::QueueLoader do
    it "читает очередь и нормализует банк" do
      operations = described_class.load(data_path("operations_queue_10.json"))
      expect(operations.size).to eq(10)
      expect(operations.first.bank).to eq("sberbank")
      expect(operations.first.amount).to eq(15_000)
    end

    it "подставляет время заявкам без created_at, сохраняя порядок" do
      raw = [{ "operation_id" => "a", "amount" => 100 }, { "operation_id" => "b", "amount" => 100 }]
      operations = described_class.new(raw, default_time: Builders::T0).call
      expect(operations.map(&:created_at)).to eq([Builders::T0, Builders::T0 + 1])
    end

    it "без базового времени опирается на самое раннее created_at, иначе на фиксированную эпоху — не на часы" do
      mixed = [{ "operation_id" => "a", "amount" => 100 },
               { "operation_id" => "b", "amount" => 100, "created_at" => "2026-07-30T09:05:00Z" }]
      expect(described_class.new(mixed).call.first.created_at).to eq(Time.iso8601("2026-07-30T09:05:00Z"))

      bare = [{ "operation_id" => "a", "amount" => 100 }]
      expect(described_class.new(bare).call.first.created_at).to eq(described_class::EPOCH)
    end

    it "читает валюту (в верхнем регистре) и сумму, записанную строкой" do
      raw = [{ "operation_id" => "a", "amount" => "15000", "currency" => "usd" }]
      operation = described_class.new(raw, default_time: Builders::T0).call.first
      expect(operation.amount).to eq(15_000)
      expect(operation.currency).to eq("USD")
      expect { described_class.new([{ "operation_id" => "a", "amount" => "many" }]).call }
        .to raise_error(PayoutRouter::InputError, /должно быть числом/)
    end

    it "терпит числовой operation_id и дату без «T», но не мусор" do
      raw = [{ "operation_id" => 103, "amount" => 100, "created_at" => "2026-07-30 09:05:00" }]
      operation = described_class.new(raw).call.first
      expect(operation.operation_id).to eq("103")
      expect(operation.created_at).to eq(Time.new(2026, 7, 30, 9, 5, 0))
      expect { described_class.new([{ "operation_id" => "a", "amount" => 1, "created_at" => "вчера" }]).call }
        .to raise_error(PayoutRouter::InputError, /ISO 8601/)
      expect { described_class.new([{ "operation_id" => nil, "amount" => 1 }]).call }
        .to raise_error(PayoutRouter::InputError, /operation_id обязательно/)
    end

    it "отвергает неположительную сумму и дубликаты operation_id" do
      expect { described_class.new([{ "operation_id" => "a", "amount" => 0 }]).call }
        .to raise_error(PayoutRouter::InputError, /заявка a.*положительной/)
      raw = [{ "operation_id" => "a", "amount" => 1 }, { "operation_id" => "a", "amount" => 2 }]
      expect { described_class.new(raw).call }.to raise_error(PayoutRouter::InputError, /повторяется/)
    end

    it "требует массив" do
      expect { described_class.new({}).call }.to raise_error(PayoutRouter::InputError, /массив заявок/)
    end
  end

  describe PayoutRouter::Inputs::HistoryLoader do
    it "читает историю организаторов" do
      records = described_class.load(data_path("operations_history.csv"))
      expect(records.size).to eq(100)
      expect(records.first.provider).to eq("vipay")
      expect(records.map(&:status).uniq).to contain_exactly("approved", "rejected", "expired")
    end

    it "проверяет колонки и статусы" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "h.csv")
        File.write(path, "operation_id,amount\nop,10\n")
        expect { described_class.load(path) }.to raise_error(PayoutRouter::InputError, /нет колонок/)
        File.write(path, "operation_id,amount,bank,payment_system,status\nop,10,vtb,vipay,weird\n")
        expect { described_class.load(path) }.to raise_error(PayoutRouter::InputError, /status должен/)
      end
    end
  end

  describe PayoutRouter::Inputs::PolicyLoader do
    it "читает политику по умолчанию и пресеты" do
      Dir[config_path("**/*.yml")].each do |path|
        policy = described_class.load(path)
        expect(policy.enabled_goals.any? || policy.selection.chain?).to be(true)
        expect(policy.fallback_provider).to eq("spacepayments")
      end
    end

    it "ловит опечатки в правилах, целях, tie-breakers и параметрах провайдеров" do
      expect do
        build_policy("hard_constraints" => ["bank_filtr"])
      end.to raise_error(PayoutRouter::PolicyError, /bank_filtr/)
      expect do
        build_policy("goals" => { "conversions" => 1 })
      end.to raise_error(PayoutRouter::PolicyError, /conversions/)
      expect do
        build_policy("tie_breakers" => ["speed"])
      end.to raise_error(PayoutRouter::PolicyError, /tie_breaker «speed»/)
      expect do
        build_policy("providers" => { "vipay" => { "rpm" => 1 } })
      end.to raise_error(PayoutRouter::PolicyError,
                         /неизвестный параметр rpm/)
    end

    it "требует хотя бы одну включённую цель и валидную симуляцию" do
      expect do
        build_policy("goals" => { "conversion" => 0 })
      end.to raise_error(PayoutRouter::PolicyError, /ни одна цель/)
      expect do
        build_policy("simulation" => { "mode" => "random" })
      end.to raise_error(PayoutRouter::PolicyError, /simulation.mode/)
      expect do
        build_policy("simulation" => { "timeout" => "ignore" })
      end.to raise_error(PayoutRouter::PolicyError, %r{simulation.timeout.*cascade/hold})
      expect do
        build_policy("share_targets" => "fair")
      end.to raise_error(PayoutRouter::PolicyError, %r{share_targets.*absolute/attainable})
    end
  end

  describe PayoutRouter::Inputs::StateUpdate do
    it "принимает и массив в формате providers.json, и объект «провайдер → поля»" do
      from_array = described_class.parse([{ "payment_system" => "vipay", "in_progress_count" => 7,
                                            "status" => "inactive", "avg_latency_sec" => nil }])
      expect(from_array).to eq("vipay" => { in_progress_count: 7, status: "inactive" })

      expect(described_class.parse({ "vipay" => { "available_requisites" => 0 } }))
        .to eq("vipay" => { available_requisites: 0 })
      expect(described_class.parse(nil)).to eq({})
    end

    it "проверяет типы и диапазоны и не молчит про неизвестное поле" do
      expect do
        described_class.parse({ "vipay" => { "in_progress_count" => -1 } })
      end.to raise_error(PayoutRouter::InputError, /in_progress_count = -1 меньше допустимого 0/)
      expect do
        described_class.parse({ "vipay" => { "conversion_24h" => 1.5 } })
      end.to raise_error(PayoutRouter::InputError, /conversion_24h/)
      expect do
        described_class.parse({ "vipay" => { "in_progres_count" => 1 } })
      end.to raise_error(PayoutRouter::InputError, /нельзя обновлять извне/)
      expect do
        described_class.parse("что-то не то")
      end.to raise_error(PayoutRouter::InputError, /массив провайдеров или объект/)
    end
  end
end
