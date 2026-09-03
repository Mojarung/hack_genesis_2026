# frozen_string_literal: true

module PayoutRouter
  module Analytics
    # Показатели истории операций по провайдерам: доли, конверсия, отказы/таймауты, задержки,
    # исходы по банкам. Один проход по записям; результат используют симуляция (доля expired),
    # стратегии (bank_affinity), модель одобрения, отчёт и рекомендации.
    class HistoryStats
      # Исходы пары провайдер × банк.
      class BankOutcome
        attr_accessor :operations, :approved

        def initialize
          @operations = 0
          @approved = 0
        end
      end

      class ProviderStats
        attr_accessor :operations, :volume, :approved, :rejected, :expired,
                      :latency_sum, :latency_count, :expired_latency_sum
        attr_reader :banks, :bank_outcomes

        def initialize
          @operations = @volume = @approved = @rejected = @expired = 0
          @latency_sum = @latency_count = @expired_latency_sum = 0
          @banks = Hash.new(0)
          @bank_outcomes = Hash.new { |hash, bank| hash[bank] = BankOutcome.new }
        end

        def conversion = operations.zero? ? nil : approved.to_f / operations
        def rejected_share = operations.zero? ? nil : rejected.to_f / operations
        def expired_rate = operations.zero? ? nil : expired.to_f / operations
        def expired_share = (rejected + expired).zero? ? nil : expired.to_f / (rejected + expired)
        def avg_latency = latency_count.zero? ? nil : latency_sum.to_f / latency_count
        def avg_expired_latency = expired.zero? ? nil : expired_latency_sum.to_f / expired
        def avg_amount = operations.zero? ? nil : volume.to_f / operations
      end

      attr_reader :total_operations, :total_volume

      # Бакеты суммы чека: конверсия заметно зависит от размера выплаты.
      AMOUNT_BUCKETS = [["<=1000", 0, 1_000], ["1001-50000", 1_001, 50_000], ["50001-100000", 50_001, 100_000],
                        [">100000", 100_001, Float::INFINITY]].freeze
      Z95 = 1.96

      def initialize(records)
        @by_provider = Hash.new { |hash, name| hash[name] = ProviderStats.new }
        @banks = Hash.new(0)
        @amount_buckets = AMOUNT_BUCKETS.to_h { |label, _from, _to| [label, BankOutcome.new] }
        @total_operations = 0
        @total_volume = 0
        records.each { |record| add(record) }
      end

      def empty? = @total_operations.zero?
      def providers = @by_provider.keys.sort
      def for(name) = @by_provider.fetch(name, nil)
      def banks = @banks.sort_by { |_bank, count| -count }.to_h

      def count_share_pct(name) = empty? ? 0.0 : stats_of(name).operations * 100.0 / @total_operations
      def volume_share_pct(name) = @total_volume.zero? ? 0.0 : stats_of(name).volume * 100.0 / @total_volume
      def conversion(name) = self.for(name)&.conversion
      def expired_share(name) = self.for(name)&.expired_share
      def avg_expired_latency(name) = self.for(name)&.avg_expired_latency
      def bank_share_pct(bank) = empty? ? 0.0 : @banks.fetch(bank, 0) * 100.0 / @total_operations

      # Наблюдения провайдера: [заявок, одобрено]. exclude — запись, которую не учитываем
      # (leave-one-out для честного бэктеста). Без истории — [0, 0]. Сглаживание — в ApprovalModel.
      def provider_counts(provider, exclude: nil)
        stats = self.for(provider)
        return [0, 0] if stats.nil?

        counts_without(stats.operations, stats.approved, exclude, provider, nil)
      end

      # Наблюдения пары провайдер × банк: [заявок, одобрено].
      def bank_counts(provider, bank, exclude: nil)
        outcome = bank_outcome(provider, bank)
        return [0, 0] if outcome.nil?

        counts_without(outcome.operations, outcome.approved, exclude, provider, bank)
      end

      # 95% доверительный интервал Уилсона для конверсии провайдера: на 20–40 наблюдениях
      # разброс велик, и «заявлено 0.87 против 0.78 в истории» может быть шумом, а 0.91 против 0.47 — нет.
      def conversion_interval(provider)
        stats = self.for(provider)
        return nil if stats.nil? || stats.operations.zero?

        n = stats.operations.to_f
        p_hat = stats.approved / n
        denominator = 1 + ((Z95**2) / n)
        center = (p_hat + ((Z95**2) / (2 * n))) / denominator
        half = Z95 * Math.sqrt((p_hat * (1 - p_hat) / n) + ((Z95**2) / (4 * n * n))) / denominator
        [(center - half).round(3), (center + half).round(3)]
      end

      # Конверсия по размеру чека (все провайдеры вместе).
      def amount_buckets
        @amount_buckets.to_h do |label, outcome|
          conversion = outcome.operations.zero? ? nil : (outcome.approved.to_f / outcome.operations).round(3)
          [label, { "operations" => outcome.operations, "approved" => outcome.approved, "conversion" => conversion }]
        end
      end

      def serialize
        {
          "operations" => @total_operations,
          "volume" => @total_volume,
          "providers" => providers.to_h { |name| [name, serialize_provider(name)] },
          "banks" => banks.to_h do |bank, count|
            [bank, { "operations" => count, "share_pct" => bank_share_pct(bank).round(1) }]
          end,
          "amount_buckets" => amount_buckets
        }
      end

      private

      def stats_of(name) = @by_provider.fetch(name) { ProviderStats.new }

      def bank_outcome(provider, bank)
        return nil if bank.nil?

        self.for(provider)&.bank_outcomes&.fetch(bank, nil)
      end

      # Вычесть саму запись, если она относится к этой паре провайдер × банк.
      def counts_without(operations, approved, record, provider, bank)
        return [operations, approved] if record.nil? || record.provider != provider || (bank && record.bank != bank)

        [operations - 1, approved - (record.approved? ? 1 : 0)]
      end

      def add(record)
        stats = @by_provider[record.provider]
        stats.operations += 1
        stats.volume += record.amount
        add_bank(stats, record)
        add_bucket(record)
        @total_operations += 1
        @total_volume += record.amount
        add_outcome(stats, record)
      end

      def add_bucket(record)
        label, = AMOUNT_BUCKETS.find { |_label, from, to| record.amount.between?(from, to) }
        return if label.nil?

        bucket = @amount_buckets[label]
        bucket.operations += 1
        bucket.approved += 1 if record.approved?
      end

      def add_bank(stats, record)
        return if record.bank.nil?

        stats.banks[record.bank] += 1
        @banks[record.bank] += 1
        outcome = stats.bank_outcomes[record.bank]
        outcome.operations += 1
        outcome.approved += 1 if record.approved?
      end

      def add_outcome(stats, record)
        if record.approved?
          stats.approved += 1
          if record.latency_sec
            stats.latency_sum += record.latency_sec
            stats.latency_count += 1
          end
        elsif record.expired?
          stats.expired += 1
          stats.expired_latency_sum += record.latency_sec.to_i
        else
          stats.rejected += 1
        end
      end

      def serialize_provider(name)
        stats = stats_of(name)
        {
          "operations" => stats.operations,
          "count_share_pct" => count_share_pct(name).round(1),
          "volume" => stats.volume,
          "volume_share_pct" => volume_share_pct(name).round(1),
          "avg_amount" => stats.avg_amount&.round,
          "approved" => stats.approved,
          "rejected" => stats.rejected,
          "expired" => stats.expired,
          "conversion" => stats.conversion&.round(3),
          "rejected_pct" => ((stats.rejected_share || 0) * 100).round(1),
          "expired_pct" => ((stats.expired_rate || 0) * 100).round(1),
          "avg_latency_sec" => stats.avg_latency&.round,
          "avg_expired_latency_sec" => stats.avg_expired_latency&.round,
          "banks" => stats.banks.sort_by { |_bank, count| -count }.to_h,
          "bank_conversion" => bank_conversions(stats)
        }
      end

      def bank_conversions(stats)
        stats.bank_outcomes.sort_by { |_bank, outcome| -outcome.operations }.to_h do |bank, outcome|
          [bank, { "operations" => outcome.operations, "approved" => outcome.approved,
                   "conversion" => (outcome.approved.to_f / outcome.operations).round(3) }]
        end
      end
    end
  end
end
