# frozen_string_literal: true

module PayoutRouter
  module Stress
    # Каталог стресс-сценариев. Каждый давит на роутер с одной стороны и отвечает
    # на конкретный вопрос «а что будет, если…».
    #
    # Всё детерминировано: суммы и банки берутся из фиксированных списков по seed,
    # время считается от snapshot_at. Два прогона дают одинаковые числа, иначе
    # стресс-отчёт нельзя было бы сравнивать между коммитами.
    class Catalog
      BANKS = %w[sberbank tinkoff vtb alfa raiffeisen gazprombank].freeze
      AMOUNTS = [800, 1_500, 5_000, 12_000, 25_000, 45_000, 55_000, 95_000, 150_000].freeze
      # Потолки и то, что уже израсходовано, масштабируются по-разному: потолки округляем вверх
      # (и не ниже 1), израсходованное — вниз. Иначе снимок стартует за пределами урезанного
      # лимита и провайдер выбывает ещё до первой заявки — сценарий мерил бы кривую подготовку.
      CAPACITY_CEILINGS = %i[daily_amount_limit in_progress_count_limit in_progress_amount_limit
                             available_requisites requests_per_minute_limit daily_turnover_max].freeze
      CAPACITY_USED = %i[daily_approved_amount in_progress_count in_progress_amount].freeze
      SHRINK_FACTOR = 10.0
      # Границы «провайдер выключен» в сценарии provider_dies — по ним же спек режет прогон
      # на три отрезка, поэтому они здесь, а не зашиты в двух местах.
      DIES_AT = 60
      BACK_AT = 260
      # Границы окна «провайдер забит» в сценарии counter_snapshot.
      SATURATED_FROM = 100
      SATURATED_TO = 300

      def initialize(snapshot:, policy:)
        @snapshot = policy.apply(snapshot)
        @policy = policy
        @start_at = @snapshot.snapshot_at || Time.utc(2026, 1, 1)
      end

      def all = ORDER.map { |key| public_send(key) }

      def fetch(key)
        raise InputError, "нет такого сценария: #{key} (есть: #{ORDER.join(", ")})" unless ORDER.include?(key.to_sym)

        public_send(key.to_sym)
      end

      def keys = ORDER

      # Все заявки в одну секунду: никакого времени между ними, ответы провайдеров не успевают
      # прийти. Проверяет, что заявки не дерутся за одну и ту же ёмкость и никто не теряется.
      def burst
        scenario(:burst, "Залп: 500 заявок в одну секунду",
                 note: "ответы не успевают прийти, вся ёмкость занята одновременно",
                 operations: queue(500, step: 0))
      end

      # Долгая ровная нагрузка: лимиты выбираются постепенно, видно, как роутер деградирует
      # к fallback по мере исчерпания дневных лимитов.
      def flood
        scenario(:flood, "Поток: 3000 заявок с шагом 1–5 с",
                 note: "дневные лимиты выбираются по ходу — видно переход на self-provider",
                 operations: queue(3_000))
      end

      # Все внешние отказывают. Каскад обязан дойти до конца и увести заявку на self-provider.
      def all_reject
        scenario(:all_reject, "Все внешние отказывают",
                 note: "conversion_24h = 0 у внешних: каскад до последнего кандидата, потом fallback",
                 snapshot: map_external { |provider| provider.with(conversion_24h: 0.0) },
                 operations: queue(400),
                 simulator: Simulation::Conversion.new(seed: 7))
      end

      # Провайдер выключается посреди очереди и через сотню заявок возвращается — внешняя система
      # присылает и статус, и ёмкостные счётчики. Ёмкость намеренно свободная (roomy): иначе
      # провайдер замолчал бы сам, упёршись в дневной лимит, и сценарий проверял бы не снимок,
      # а арифметику лимитов — ровно та ловушка, в которую он сначала и попал.
      def provider_dies
        killed = @snapshot.external.first.name
        scenario(:provider_dies, "Провайдер выключается и возвращается посреди очереди",
                 note: "снимок гасит #{killed} на заявке #{DIES_AT} и возвращает на #{BACK_AT}",
                 snapshot: map_external { |provider| roomy(provider) },
                 operations: queue(400),
                 before_each: lambda { |ledger, _operation, position|
                   ledger.sync!(killed => { status: "inactive" }) if position == DIES_AT
                   ledger.sync!(killed => { status: "active" }) if position == BACK_AT
                 })
      end

      # Источник истины по ёмкости — вызывающая система: она присылает счётчики перед каждой
      # заявкой. В окне [SATURATED_FROM, SATURATED_TO) сообщает, что провайдер забит под завязку,
      # вне окна — что свободен. Роутер обязан слушаться присланных чисел, а не своих.
      def counter_snapshot
        roomy_snapshot = map_external { |provider| roomy(provider) }
        name = roomy_snapshot.external.first.name
        # Дневной оборот выбран не случайно: ответы провайдеров его только увеличивают, поэтому
        # объявленное «исчерпан» держится всё окно. Счётчик in-progress ответы уменьшают,
        # и провайдер разблокировался бы сам — сценарий проверял бы не снимок, а наши часы.
        exhausted = roomy_snapshot.provider(name).daily_amount_limit
        scenario(:counter_snapshot, "Счётчики приходят извне",
                 note: "система объявляет дневной лимит #{name} исчерпанным " \
                       "на заявках #{SATURATED_FROM}–#{SATURATED_TO}",
                 snapshot: roomy_snapshot,
                 operations: queue(400),
                 before_each: lambda { |ledger, _operation, position|
                   busy = position >= SATURATED_FROM && position < SATURATED_TO
                   ledger.sync!(name => { daily_approved_amount: busy ? exhausted : 0 })
                 })
      end

      # Весь трафик в банк, который поддерживает один провайдер: концентрация упирается
      # в его интенсивность и дневной лимит, остальное уходит на fallback.
      def single_bank
        scenario(:single_bank, "Один банк — один провайдер",
                 note: "все заявки в raiffeisen: его берёт только quickpay",
                 operations: queue(400, banks: %w[raiffeisen]))
      end

      # Суммы ровно на границах диапазонов провайдеров и на 1 ₽ по обе стороны.
      def amount_edges
        scenario(:amount_edges, "Суммы на границах диапазонов",
                 note: "limit_amount_min/max каждого провайдера и ±1 ₽ вокруг",
                 operations: edge_queue)
      end

      # Все внешние выключены: работает только self-provider.
      def no_external
        scenario(:no_external, "Все внешние выключены",
                 note: "status: inactive у всех внешних — весь трафик на self-provider",
                 snapshot: map_external { |provider| provider.with(status: "inactive") },
                 operations: queue(200))
      end

      # Ни внешних, ни fallback: единственный сценарий, где заявка без маршрута — не баг.
      # Нужен, чтобы убедиться, что мы отвечаем честным «не смогли», а не падаем и не врём.
      def no_route
        scenario(:no_route, "Некуда маршрутизировать",
                 note: "нет fallback-провайдера, внешние выключены — заявки честно без маршрута",
                 snapshot: @snapshot.with(providers: @snapshot.external.map { |p| p.with(status: "inactive") }),
                 operations: queue(100),
                 allow_unrouted: true)
      end

      # Лимиты урезаны: внешние принимают заявки, но по одной за раз и быстро упираются в потолки.
      def tiny_limits
        scenario(:tiny_limits, "Лимиты урезаны в 10 раз",
                 note: "внешние работают, но каждая заявка сразу занимает весь запас ёмкости",
                 snapshot: map_external { |provider| shrink(provider) },
                 operations: queue(300))
      end

      # Очередь приходит вперемешку по времени: роутер обязан обработать её хронологически.
      def clock_chaos
        scenario(:clock_chaos, "Время вперемешку",
                 note: "заявки в файле не отсортированы по created_at",
                 operations: queue(300).shuffle(random: Random.new(11)))
      end

      # Низкая конверсия и длинная очередь: предохранитель обязан сработать и отпустить.
      def circuit_storm
        scenario(:circuit_storm, "Шторм отказов",
                 note: "conversion_24h 0.05: предохранитель размыкается и возвращает провайдеров",
                 snapshot: map_external { |provider| provider.with(conversion_24h: 0.05) },
                 operations: queue(500),
                 simulator: Simulation::Conversion.new(seed: 3))
      end

      # Длинная очередь при достаточной ёмкости: единственный сценарий, где доли меряют стратегию,
      # а не арифметику лимитов. В остальных внешние упираются в дневные потолки, и отклонение
      # от целей говорит только о том, что ёмкости не хватило.
      def share_pressure
        scenario(:share_pressure, "Давление на доли: 2000 заявок при свободной ёмкости",
                 note: "лимиты ×100 и обнулённые счётчики — отклонение от целей меряет стратегию",
                 snapshot: map_external { |provider| roomy(provider) },
                 operations: queue(2_000))
      end

      # Тот же поток, но дневной лимит резервируется под заявки в обработке. Прямое сравнение
      # с flood: видно, что формула ТЗ переливает через дневной лимит, а строгое правило — нет.
      def reserved_limits
        strict = @policy.with(hard_constraints: @policy.hard_constraints.map do |key|
          key == Constraints::DailyLimit.key ? Constraints::DailyLimitReserved.key : key
        end)
        scenario(:reserved_limits, "Поток со строгим дневным лимитом",
                 note: "то же, что flood, но daily_limit_reserved: лимит держится под in-progress",
                 operations: queue(3_000), policy: strict)
      end

      # Заявки, которые проходят hard-правила у ВСЕХ трёх внешних: банк из общего списка,
      # сумма в пересечении диапазонов, ёмкости с запасом. Единственный сценарий, где выбор есть
      # в каждой заявке и распределение определяет только скоринг. Во всех остальных большинство
      # заявок имеет одного допустимого кандидата — там отклонение от целей меряет hard-правила,
      # а не стратегию, и путать это нельзя.
      def open_field
        scenario(:open_field, "Свободное поле: в каждой заявке допустимы все трое",
                 note: "банк и суммы в пересечении всех диапазонов — решает только скоринг",
                 snapshot: map_external { |provider| roomy(provider) },
                 operations: open_queue)
      end

      # То же поле, но цели по долям выключены. Пара к open_field: разница между ними —
      # и есть вклад стратегий распределения, измеренный, а не заявленный.
      def open_field_no_shares
        scenario(:open_field_no_shares, "Свободное поле без целей по долям",
                 note: "контроль к open_field: traffic_share и volume_share с весом 0",
                 snapshot: map_external { |provider| roomy(provider) },
                 operations: open_queue,
                 policy: @policy.with_goals("traffic_share" => 0.0, "volume_share" => 0.0))
      end

      # Таймауты, которые не освобождают ёмкость (simulation.timeout: hold). Ветка, где провайдер
      # может залипнуть навсегда: заявка занимает слот и реквизит, а ответа не будет никогда.
      def held_timeouts
        scenario(:held_timeouts, "Таймауты с удержанием ёмкости",
                 note: "simulation.timeout: hold — неотвеченные заявки навсегда занимают слот",
                 operations: queue(400),
                 policy: @policy.with(simulation: @policy.simulation.with(mode: "conversion", timeout: "hold")),
                 simulator: Simulation::Conversion.new(seed: 9))
      end

      ORDER = %i[burst flood reserved_limits all_reject provider_dies counter_snapshot single_bank
                 amount_edges no_external no_route tiny_limits clock_chaos circuit_storm
                 held_timeouts share_pressure open_field open_field_no_shares].freeze

      private

      def scenario(key, title, operations:, note: nil, snapshot: nil, policy: nil, simulator: nil,
                   allow_unrouted: false, before_each: nil)
        Scenario.new(key: key, title: title, note: note, operations: operations,
                     snapshot: snapshot || @snapshot, policy: policy || @policy,
                     simulator: simulator || Simulation::Optimistic.new,
                     allow_unrouted: allow_unrouted, before_each: before_each)
      end

      def queue(count, step: nil, banks: BANKS, amounts: AMOUNTS)
        rng = Random.new(count)
        at = @start_at
        Array.new(count) do |index|
          at += step || (1 + rng.rand(5))
          Domain::Operation.new(operation_id: "stress_#{index + 1}", created_at: at,
                                amount: amounts[rng.rand(amounts.size)], bank: banks[rng.rand(banks.size)])
        end
      end

      # Заявки, допустимые у всех внешних сразу: банк из пересечения списков (пустой список
      # у провайдера значит «любой банк»), сумма — из пересечения диапазонов чека.
      def open_queue
        banks = @snapshot.external.filter_map { |provider| provider.banks unless provider.banks.empty? }
        bank = banks.reduce(:&).first || BANKS.first
        low = @snapshot.external.filter_map(&:limit_amount_min).max
        high = @snapshot.external.filter_map(&:limit_amount_max).min
        amounts = (1..8).map { |step| low + ((high - low) * step / 9) }
        queue(2_000, banks: [bank], amounts: amounts)
      end

      # По три заявки на каждую границу каждого провайдера: ровно граница и ±1 ₽.
      def edge_queue
        bounds = @snapshot.external.flat_map do |provider|
          [provider.limit_amount_min, provider.limit_amount_max].compact
        end.uniq.sort
        amounts = bounds.flat_map { |bound| [bound - 1, bound, bound + 1] }.select(&:positive?).uniq
        at = @start_at
        BANKS.flat_map do |bank|
          amounts.map do |amount|
            at += 1
            Domain::Operation.new(operation_id: "edge_#{bank}_#{amount}", created_at: at,
                                  amount: amount, bank: bank)
          end
        end
      end

      def map_external(&)
        @snapshot.with(providers: @snapshot.providers.map do |provider|
          provider.external? ? yield(provider) : provider
        end)
      end

      def shrink(provider)
        ceilings = CAPACITY_CEILINGS.to_h do |field|
          value = provider.public_send(field)
          [field, value && [(value / SHRINK_FACTOR).ceil, 1].max]
        end
        used = CAPACITY_USED.to_h { |field| [field, (provider.public_send(field).to_i / SHRINK_FACTOR).floor] }
        provider.with(**ceilings, **used)
      end

      # Много ёмкости и чистый старт: потолки ×100, израсходованное обнулено.
      def roomy(provider)
        provider.with(**CAPACITY_CEILINGS.to_h { |field| [field, provider.public_send(field)&.*(100)] },
                      **CAPACITY_USED.to_h { |field| [field, 0] })
      end
    end
  end
end
