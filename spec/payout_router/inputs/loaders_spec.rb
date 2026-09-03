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
    end
  end
end
