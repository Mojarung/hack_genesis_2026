# frozen_string_literal: true

module PayoutRouter
  module Strategies
    # Реестр целей: встроенные плюс плагины. Плагин — любой наследник Strategies::Base,
    # загруженный через policy.yml → plugins; discover! подхватывает его без правки этого файла.
    module Registry
      @by_key = {}

      def self.register(klass)
        @by_key[klass.key] = klass
        klass
      end

      def self.discover!
        Base.subclasses.each do |klass|
          next if klass.name.to_s.include?("::Custom::") || @by_key.value?(klass)

          register(klass)
        end
      end

      def self.keys = @by_key.keys
      def self.registered?(key) = @by_key.key?(key)

      def self.describe(key)
        DESCRIPTIONS.fetch(key) do
          klass = @by_key[key]
          klass.respond_to?(:description) ? klass.description : "плагин"
        end
      end

      def self.fetch(key)
        @by_key.fetch(key) do
          raise PolicyError, "неизвестная цель «#{key}» (доступны: #{keys.join(", ")})"
        end
      end

      BUILTIN = [
        TrafficShare, VolumeShare, CascadePriority, AmountBand, Conversion, Load,
        TurnoverMin, RateHeadroom, Latency, Margin, BankAffinity, ExpectedValue
      ].freeze
      BUILTIN.each { |klass| register(klass) }

      DESCRIPTIONS = {
        "traffic_share" => "стратегия 1: целевая доля по числу заявок (traffic_percentage); недобор поднимает оценку",
        "volume_share" => "стратегия 2: целевая доля по объёму (volume_share_pct); база — оборот дня + сессия",
        "cascade_priority" => "стратегия 3: очередь в каскаде по priority; первый — 1.0, последний — 0.0",
        "amount_band" => "стратегия 4: предпочтительный провайдер для диапазона суммы (amount_bands)",
        "conversion" => "стратегия 5: заявленная conversion_24h",
        "rate_headroom" => "стратегия 6: запас по интенсивности (requests_per_minute_limit)",
        "turnover_min" => "стратегия 7: фин. обязательство «не менее X ₽/сутки» — недобор поднимает оценку",
        "load" => "загрузка лимитов: чем ближе к дневному/in-progress лимиту, тем ниже оценка",
        "bank_affinity" => "сглаженная конверсия пары провайдер × банк по истории (без истории нейтральна)",
        "expected_value" => "ожидаемая маржа: конверсия × (маржа мерчанта − маржа провайдера)",
        "latency" => "скорость ответа: самый медленный — 0, мгновенный — 1",
        "margin" => "стоимость: чем меньше провайдер откусывает от маржи мерчанта, тем выше"
      }.freeze
    end
  end
end
