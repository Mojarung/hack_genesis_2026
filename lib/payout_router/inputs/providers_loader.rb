# frozen_string_literal: true

module PayoutRouter
  module Inputs
    # providers.json → Domain::Snapshot. Проверяет типы и диапазоны полей;
    # отсутствующий лимит (null) означает «лимита нет».
    class ProvidersLoader
      def self.load(path) = new(JSONFile.read(path), source: path).call

      def initialize(document, source: "providers.json")
        @document = document
        @source = source
      end

      def call
        unless @document.is_a?(Hash) && @document["providers"].is_a?(Array)
          raise InputError, "#{@source}: ожидается объект с массивом providers"
        end

        gateway = Fields.string(@document, "gateway", where: @source)
        @currency = (Fields.string(@document, "currency", where: @source) || gateway_currency(gateway))&.upcase
        providers = @document["providers"].each_with_index.map { |raw, index| build(raw, index) }
        ensure_unique!(providers)
        Domain::Snapshot.new(
          snapshot_at: Fields.time(@document, "snapshot_at", where: @source),
          gateway: gateway,
          merchant: Fields.string(@document, "merchant", where: @source),
          providers: providers
        )
      end

      private

      # Валюта шлюза: явное поле currency, иначе префикс имени шлюза (RUB_SBP_WITHDRAW → RUB).
      def gateway_currency(gateway) = gateway.to_s[/\A([A-Za-z]{3})_/, 1]

      def build(raw, index)
        raise InputError, "#{@source} providers[#{index}]: ожидается объект" unless raw.is_a?(Hash)

        name = Fields.string!(raw, "payment_system", where: "#{@source} providers[#{index}]")
        where = "#{@source} провайдер #{name}"
        provider = Domain::Provider.new(name: name, **limits(raw, where), **counters(raw, where), **terms(raw, where))
        check_amount_range!(provider, where)
        provider
      end

      def limits(raw, where)
        {
          status: Fields.string!(raw, "status", where: where),
          currency: (Fields.string(raw, "currency", where: where) || @currency)&.upcase,
          traffic_percentage: Fields.number(raw, "traffic_percentage", where: where, min: 0, max: 100) || 0,
          priority: Fields.number(raw, "priority", where: where) || Domain::Provider::DEFAULT_PRIORITY,
          limit_amount_min: Fields.number(raw, "limit_amount_min", where: where, min: 0),
          limit_amount_max: Fields.number(raw, "limit_amount_max", where: where, min: 0),
          daily_amount_limit: Fields.number(raw, "daily_amount_limit", where: where, min: 0),
          in_progress_count_limit: Fields.number(raw, "in_progress_count_limit", where: where, min: 0),
          in_progress_amount_limit: Fields.number(raw, "in_progress_amount_limit", where: where, min: 0)
        }
      end

      def counters(raw, where)
        {
          daily_approved_amount: Fields.number(raw, "daily_approved_amount", where: where, min: 0) || 0,
          in_progress_count: Fields.number(raw, "in_progress_count", where: where, min: 0) || 0,
          in_progress_amount: Fields.number(raw, "in_progress_amount", where: where, min: 0) || 0,
          available_requisites: Fields.number(raw, "available_requisites", where: where, min: 0) || 0,
          conversion_24h: Fields.number(raw, "conversion_24h", where: where, min: 0, max: 1) || 0.0,
          avg_latency_sec: Fields.number(raw, "avg_latency_sec", where: where, min: 0)
        }
      end

      def terms(raw, where)
        {
          banks: Fields.string_list(raw, "banks", where: where),
          exclude_banks: Fields.boolean(raw, "exclude_banks", where: where),
          provider_margin_pct: Fields.number(raw, "provider_margin_pct", where: where) || 0,
          merchant_margin_pct: Fields.number(raw, "merchant_margin_pct", where: where) || 0,
          allow_negative_agreement: Fields.boolean(raw, "allow_negative_agreement", where: where)
        }
      end

      def check_amount_range!(provider, where)
        min = provider.limit_amount_min
        max = provider.limit_amount_max
        return unless min && max && min > max

        raise InputError, "#{where}: limit_amount_min #{min} больше limit_amount_max #{max}"
      end

      def ensure_unique!(providers)
        duplicates = providers.map(&:name).tally.select { |_name, count| count > 1 }.keys
        return if duplicates.empty?

        raise InputError, "#{@source}: провайдеры повторяются: #{duplicates.join(", ")}"
      end
    end
  end
end
