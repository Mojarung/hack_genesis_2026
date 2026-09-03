# frozen_string_literal: true

module PayoutRouter
  module Analytics
    # Показатели истории операций по провайдерам: доли, конверсия, отказы/таймауты, задержки, банки.
    # Один проход по записям; результат используют симуляция (доля expired), отчёт и рекомендации.
    class HistoryStats
      class ProviderStats
        attr_accessor :operations, :volume, :approved, :rejected, :expired,
                      :latency_sum, :latency_count, :expired_latency_sum
        attr_reader :banks

        def initialize
          @operations = @volume = @approved = @rejected = @expired = 0
          @latency_sum = @latency_count = @expired_latency_sum = 0
          @banks = Hash.new(0)
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

      def initialize(records)
        @by_provider = Hash.new { |hash, name| hash[name] = ProviderStats.new }
        @banks = Hash.new(0)
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

      def serialize
        {
          "operations" => @total_operations,
          "volume" => @total_volume,
          "providers" => providers.to_h { |name| [name, serialize_provider(name)] },
          "banks" => banks.to_h do |bank, count|
            [bank, { "operations" => count, "share_pct" => bank_share_pct(bank).round(1) }]
          end
        }
      end

      private

      def stats_of(name) = @by_provider.fetch(name) { ProviderStats.new }

      def add(record)
        stats = @by_provider[record.provider]
        stats.operations += 1
        stats.volume += record.amount
        stats.banks[record.bank] += 1 if record.bank
        @banks[record.bank] += 1 if record.bank
        @total_operations += 1
        @total_volume += record.amount
        add_outcome(stats, record)
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
          "banks" => stats.banks.sort_by { |_bank, count| -count }.to_h
        }
      end
    end
  end
end
