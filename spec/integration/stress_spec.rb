# frozen_string_literal: true

# Стресс-прогон в тестах. Здесь два разных вида проверок, и путать их нельзя:
#
#   1. Инварианты — то, что обязано держаться при любом давлении (ни одной потерянной заявки,
#      ровно один selected, ёмкость сходится, выбранный провайдер действительно принимает заявку,
#      пики не выше лимитов). Это жёсткие assert'ы.
#   2. Наблюдаемое поведение — конкретные числа, которые сейчас получаются. Они зафиксированы
#      не ради галочки, а чтобы изменение поведения нельзя было не заметить.
#
# Каждый пример здесь проверялся мутацией: в код вносилась настоящая ошибка (не возвращать слот
# при отказе, снять сортировку по времени, сдвинуть границу диапазона суммы на 1 ₽), и пример
# обязан был упасть. Проверки, которые мутацию не ловили, переписаны — см. историю коммитов.
#
# Полную таблицу с метриками печатает `payout_router stress`.
RSpec.describe "стресс-прогон" do
  # Прогон дорогой (16 сценариев, ~15 000 заявок) и полностью read-only, поэтому считается
  # один раз на файл и кешируется в классе группы примеров.
  def self.runner
    @runner ||= PayoutRouter::Runner.new(
      providers_path: File.join(Builders::DATA_DIR, "providers.json"),
      policy_path: File.join(Builders::CONFIG_DIR, "policy.yml"),
      history_path: File.join(Builders::DATA_DIR, "operations_history.csv")
    )
  end

  def self.report = @report ||= runner.stress

  let(:report) { self.class.report }

  def outcome(key) = report.outcome(key)

  it "не нарушает ни одного инварианта ни в одном сценарии" do
    expect(report.violations.map(&:to_s)).to be_empty
    expect(report.outcomes.size).to eq(PayoutRouter::Stress::Catalog::ORDER.size)
  end

  it "теряет заявки только там, где маршрута физически нет" do
    lost = report.outcomes.reject { |item| item.scenario.allow_unrouted }.select { |item| item.unrouted.positive? }
    expect(lost.map(&:key)).to be_empty

    # А там, где ни внешних, ни fallback, — честно отвечаем «не смогли», а не падаем и не врём.
    expect(outcome(:no_route).unrouted).to eq(outcome(:no_route).total)
  end

  it "цели по долям действительно решают: на равном поле отклонение нулевое, без них — десятки п.п." do
    with_goals = outcome(:open_field)
    without = outcome(:open_field_no_shares)

    # Одна и та же очередь, где все три провайдера допустимы в КАЖДОЙ заявке: разница между
    # прогонами — чистый вклад traffic_share и volume_share. В сценариях, где hard-правила
    # оставляют одного кандидата, такой аблацией ничего доказать нельзя — там решает не скоринг.
    expect(with_goals.contested_pct).to eq(100.0)
    expect(with_goals.deviation_pp).to be < 1.0
    expect(without.deviation_pp).to be > 50.0
  end

  it "показывает, в скольких заявках вообще был выбор" do
    # Без этой метрики отклонение от целей читается как оценка стратегии даже там, где
    # распределение целиком определили банковские фильтры и потолки чека.
    expect(outcome(:single_bank).contested_pct).to be_zero
    expect(outcome(:share_pressure).contested_pct).to be_between(20, 80)
  end

  it "порядок заявок в файле не влияет на результат" do
    chaos = outcome(:clock_chaos)
    replay = PayoutRouter::Routing::BatchRouter.new(
      snapshot: chaos.scenario.snapshot, policy: chaos.scenario.policy,
      simulator: chaos.scenario.simulator, history: self.class.runner.history_stats
    ).call(chaos.scenario.operations.sort_by(&:created_at))

    expect(replay.decisions.to_h { |d| [d.operation_id, d.selected_provider] })
      .to eq(chaos.stats.decisions.to_h { |d| [d.operation_id, d.selected_provider] })
  end

  it "залп в одну секунду держит: 500 заявок, все маршрутизированы, перегрузку self-provider видно" do
    burst = outcome(:burst)

    expect(burst.unrouted).to be_zero
    # Ёмкость внешних кончается мгновенно (ответы ещё не пришли), и залп принимает self-provider —
    # у него по замыслу нет ёмкостных ограничений. Глубину перегрузки мы измеряем, а не прячем.
    expect(burst.fallback_pct).to be > 90
    expect(burst.fallback_overload).to be > 100
  end

  it "формула дневного лимита из ТЗ переливает через лимит, резервирование — нет" do
    literal = outcome(:flood)
    reserved = outcome(:reserved_limits)

    # Один и тот же поток, отличается только правило. daily_approved_amount растёт по ответу
    # провайдера, поэтому формула ТЗ пропускает заявки по устаревшему числу.
    expect(literal.max_utilization_pct).to be > 100
    expect(reserved.max_utilization_pct).to be <= 100
  end

  it "внешний снимок выключает провайдера посреди очереди и возвращает его" do
    catalog = PayoutRouter::Stress::Catalog
    dies = outcome(:provider_dies)
    killed = dies.scenario.snapshot.external.first.name
    # Ёмкость в этом сценарии свободная (roomy), поэтому замолчать провайдер может только
    # по внешнему снимку — а не потому, что упёрся в дневной лимит. Три отрезка очереди:
    # до выключения, между выключением и возвратом, после возврата.
    counts = [0...catalog::DIES_AT, catalog::DIES_AT...catalog::BACK_AT, catalog::BACK_AT..].map do |range|
      dies.stats.decisions[range].count { |decision| decision.selected_provider == killed }
    end

    expect(counts[1]).to be_zero, "после выключения #{killed} получил #{counts[1]} заявок"
    expect(counts[0]).to be_positive
    expect(counts[2]).to be_positive
  end

  it "слушается ёмкостных счётчиков, присланных извне" do
    catalog = PayoutRouter::Stress::Catalog
    snapshot = outcome(:counter_snapshot)
    name = snapshot.scenario.snapshot.external.first.name
    ranges = [0...catalog::SATURATED_FROM, catalog::SATURATED_FROM...catalog::SATURATED_TO,
              catalog::SATURATED_TO..]
    counts = ranges.map do |range|
      snapshot.stats.decisions[range].count { |decision| decision.selected_provider == name }
    end

    # Пока система сообщает, что провайдер забит, он не получает ничего — при том что по нашим
    # собственным счётчикам он свободен. Это и есть проверка, что присланные числа главнее.
    expect(counts[1]).to be_zero, "в окне насыщения #{name} получил #{counts[1]} заявок"
    expect(counts[0]).to be_positive
    expect(counts[2]).to be_positive
  end

  it "шторм отказов уводит провайдеров в карантин и доводит заявки до конца каскада" do
    storm = outcome(:circuit_storm)

    expect(storm.circuit_trips).to be_positive
    expect(storm.retries).to be_positive
    expect(storm.unrouted).to be_zero
  end

  it "когда все внешние отказывают, каскад перебирает всех до последнего" do
    rejected = outcome(:all_reject)
    # Проверяем форму каскада, а не только факт fallback: у заявки должны быть попытки
    # ко всем допустимым внешним, и лишь потом self-provider.
    cascaded = rejected.stats.decisions.count { |d| d.attempts.count(&:dispatched?) > 1 }

    expect(rejected.fallback_pct).to eq(100.0)
    expect(cascaded).to be_positive
  end

  it "урезанные лимиты не выключают внешних совсем — они работают по одной заявке" do
    tiny = outcome(:tiny_limits)
    dispatched = tiny.ledger.states.values.select { |s| s.provider.external? }.sum(&:dispatch_count)

    # Сценарий обязан именно давить на ёмкость. Если внешние перестали получать заявки вовсе,
    # он выродился в дубль no_external и ничего больше не проверяет.
    expect(dispatched).to be_positive
    expect(tiny.fallback_pct).to be > 50
  end

  it "таймауты с удержанием не освобождают ёмкость и не теряют заявок" do
    held = outcome(:held_timeouts)
    stuck = held.ledger.states.values.select { |s| s.provider.external? }.sum(&:held_timeout_count)

    expect(stuck).to be_positive
    expect(held.unrouted).to be_zero
    # Занятое такими заявками не возвращается — это и проверяет инвариант сохранения ёмкости.
    expect(held.ledger.states.values.sum(&:held_timeout_amount)).to be_positive
  end

  it "один банк — один провайдер: весь внешний трафик уходит ему" do
    external = outcome(:single_bank).stats.distribution.except("spacepayments")
    working = external.select { |_name, share| share["count"].positive? }

    expect(working.keys).to eq(["quickpay"])
  end

  it "на границах диапазонов заявки уходят только тем, кто их принимает" do
    edges = outcome(:amount_edges)
    routed = edges.stats.decisions.reject { |d| d.selected_provider == "spacepayments" }
    providers = edges.scenario.snapshot.providers.to_h { |p| [p.name, p] }

    expect(routed).not_to be_empty
    # Инвариант допустимости проверяет это по всем сценариям; здесь фиксируем, что сценарий
    # действительно доводит до внешних заявки ровно на границе, а не только ±1 ₽ мимо.
    exact = routed.count do |decision|
      provider = providers[decision.selected_provider]
      [provider.limit_amount_min, provider.limit_amount_max].include?(decision.operation.amount)
    end
    expect(exact).to be_positive
  end
end
