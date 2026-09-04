# frozen_string_literal: true

RSpec.describe "состояние провайдеров" do
  let(:approved) { PayoutRouter::Simulation::Outcome.new(result: "approved", latency_sec: 30) }
  let(:rejected) { PayoutRouter::Simulation::Outcome.new(result: "rejected", latency_sec: 10) }
  let(:expired) { PayoutRouter::Simulation::Outcome.new(result: "expired", latency_sec: 600) }

  describe PayoutRouter::State::ProviderState do
    subject(:state) do
      described_class.new(build_provider(daily_approved_amount: 1_000, in_progress_count: 1, in_progress_amount: 500,
                                         available_requisites: 3))
    end

    it "занимает и освобождает ёмкость по ходу заявки" do
      operation = build_operation(amount: 200)
      state.dispatch!(operation, Builders::T0)
      expect([state.in_progress_count, state.in_progress_amount, state.available_requisites]).to eq([2, 700, 2])

      state.settle!(operation, approved)
      expect([state.in_progress_count, state.in_progress_amount, state.available_requisites]).to eq([1, 500, 3])
      expect(state.daily_approved_amount).to eq(1_200)
      expect(state.approved_count).to eq(1)
    end

    it "не добавляет отказ в дневной оборот" do
      operation = build_operation(amount: 200)
      state.dispatch!(operation, Builders::T0)
      state.settle!(operation, rejected)
      expect(state.daily_approved_amount).to eq(1_000)
      expect(state.rejected_count).to eq(1)
    end

    it "по умолчанию таймаут освобождает ёмкость так же, как отказ" do
      operation = build_operation(amount: 200)
      state.dispatch!(operation, Builders::T0)
      state.settle!(operation, expired)

      expect([state.in_progress_count, state.in_progress_amount, state.available_requisites]).to eq([1, 500, 3])
      expect([state.expired_count, state.held_timeout_count]).to eq([1, 0])
    end

    it "с hold_timeouts таймаут ничего не освобождает и не идёт в дневной оборот" do
      operation = build_operation(amount: 200)
      holding = described_class.new(build_provider(daily_approved_amount: 1_000, in_progress_count: 1,
                                                   in_progress_amount: 500, available_requisites: 3),
                                    hold_timeouts: true)
      holding.dispatch!(operation, Builders::T0)
      holding.settle!(operation, expired)

      expect([holding.in_progress_count, holding.in_progress_amount, holding.available_requisites]).to eq([2, 700, 2])
      expect(holding.daily_approved_amount).to eq(1_000)
      expect([holding.expired_count, holding.held_timeout_count]).to eq([1, 1])
    end

    it "принимает внешний снимок: счётчики перетирает, остальное обновляет как конфигурацию" do
      state.sync!(in_progress_count: 7, available_requisites: 0, status: "inactive")

      expect([state.in_progress_count, state.available_requisites]).to eq([7, 0])
      expect(state.provider.status).to eq("inactive")
      expect(state.provider.name).to eq("alpha")
    end

    it "считает отправки в скользящем окне" do
      state.dispatch!(build_operation, Builders::T0)
      state.dispatch!(build_operation, Builders::T0 + 30)
      expect(state.requests_within(Builders::T0 + 59)).to eq(2)
      expect(state.requests_within(Builders::T0 + 61)).to eq(1)
      expect(state.requests_within(Builders::T0 + 200)).to eq(0)
    end

    it "считает загрузку по каждому лимиту" do
      provider = build_provider(daily_amount_limit: 2_000, daily_approved_amount: 500, in_progress_count_limit: nil)
      utilization = described_class.new(provider).utilization
      expect(utilization[:daily]).to eq(0.25)
      expect(utilization[:in_progress_count]).to eq(0.0)
    end
  end

  describe PayoutRouter::State::SettlementQueue do
    subject(:queue) { described_class.new }

    before do
      queue.push(Builders::T0 + 30, :late)
      queue.push(Builders::T0 + 10, :early)
      queue.push(Builders::T0 + 10, :early_too)
    end

    it "не отдаёт записи раньше времени" do
      expect(queue.pop_due(Builders::T0 + 5)).to be_nil
      expect(queue.size).to eq(3)
    end

    it "отдаёт записи по времени, а при равном — по порядку добавления" do
      expect(queue.pop_due(Builders::T0 + 10)).to eq(:early)
      expect(queue.pop_due(Builders::T0 + 10)).to eq(:early_too)
      expect(queue.pop_due(Builders::T0 + 10)).to be_nil
      expect(queue.pop).to eq(:late)
      expect(queue).to be_empty
    end
  end

  describe PayoutRouter::State::Ledger do
    subject(:ledger) { described_class.new(build_snapshot(alpha, beta, build_fallback)) }

    let(:alpha) { build_provider(name: "alpha", daily_approved_amount: 300) }
    let(:beta) { build_provider(name: "beta", daily_approved_amount: 100) }

    it "применяет ответы только когда их время наступило" do
      operation = build_operation(amount: 50)
      ledger.dispatch!(ledger.state("alpha"), operation, approved, Builders::T0)

      ledger.settle_due(Builders::T0 + 29)
      expect(ledger.state("alpha").in_progress_count).to eq(1)
      expect(ledger.pending_settlements).to eq(1)

      ledger.settle_due(Builders::T0 + 30)
      expect(ledger.state("alpha").in_progress_count).to eq(0)
      expect(ledger.state("alpha").daily_approved_amount).to eq(350)
    end

    it "считает доли по количеству (сессия) и по объёму (снимок + сессия)" do
      expect(ledger.count_share_pct(ledger.state("alpha"))).to eq(0.0)
      expect(ledger.volume_share_pct(ledger.state("alpha"))).to eq(75.0)

      ledger.select!(ledger.state("alpha"), build_operation(amount: 100))
      ledger.select!(ledger.state("beta"), build_operation(amount: 100))
      ledger.select!(ledger.state("beta"), build_operation(amount: 100))
      expect(ledger.count_share_pct(ledger.state("beta"))).to be_within(0.01).of(66.67)
      expect(ledger.selected_amount_total).to eq(300)
    end

    it "применяет внешний снимок состояния и пропускает незнакомых провайдеров" do
      ledger.sync!("alpha" => { daily_approved_amount: 900 }, "чужой" => { in_progress_count: 3 })

      expect(ledger.state("alpha").daily_approved_amount).to eq(900)
      expect(ledger.state("beta").daily_approved_amount).to eq(100)
    end

    it "разделяет внешних провайдеров и fallback" do
      expect(ledger.external_states.map(&:name)).to eq(%w[alpha beta])
      expect(ledger.fallback_state.name).to eq("self")
    end
  end
end
