# frozen_string_literal: true

module PayoutRouter
  module Inputs
    # Внешнее обновление состояния провайдеров — то, что система может присылать вместе с очередной
    # заявкой (разъяснение экспертов на QA 04.09.2026: снимок может приходить перед каждой операцией,
    # а роутер может вести счётчики и сам). Формат — как в providers.json: массив объектов
    # с payment_system либо объект «имя провайдера → поля». Обязательных полей нет: присылают только
    # то, что изменилось; null означает «не менять». Всё, чего нет в списке ниже, — ошибка с адресом:
    # молча проглоченная опечатка в имени поля означала бы, что роутер считает по устаревшим данным.
    class StateUpdate
      NUMERIC = {
        "daily_approved_amount" => { min: 0 }, "in_progress_count" => { min: 0 },
        "in_progress_amount" => { min: 0 }, "available_requisites" => { min: 0 },
        "daily_amount_limit" => { min: 0 }, "in_progress_count_limit" => { min: 0 },
        "in_progress_amount_limit" => { min: 0 }, "limit_amount_min" => { min: 0 },
        "limit_amount_max" => { min: 0 }, "traffic_percentage" => { min: 0, max: 100 },
        "priority" => { min: 0 }, "conversion_24h" => { min: 0, max: 1 },
        "avg_latency_sec" => { min: 0 }, "requests_per_minute_limit" => { min: 0 },
        "daily_turnover_min" => { min: 0 }, "daily_turnover_max" => { min: 0 },
        "volume_share_pct" => { min: 0, max: 100 }, "provider_margin_pct" => {}, "merchant_margin_pct" => {}
      }.freeze
      STRINGS = %w[status currency].freeze
      LISTS = %w[banks].freeze
      BOOLEANS = %w[exclude_banks allow_negative_agreement].freeze
      KNOWN = (NUMERIC.keys + STRINGS + LISTS + BOOLEANS).freeze

      def self.parse(document, source: "обновление состояния") = new(document, source: source).call

      def initialize(document, source: "обновление состояния")
        @document = document
        @source = source
      end

      # → { "vipay" => { in_progress_count: 7, status: "inactive" } } для State::Ledger#sync!
      def call = entries.to_h { |name, raw| [name, fields(name, raw)] }

      private

      def entries
        case @document
        when nil then []
        when Array then @document.each_with_index.map { |raw, index| [named(raw, index), raw] }
        when Hash then @document.map { |name, raw| [name.to_s, raw] }
        else raise InputError, "#{@source}: ожидается массив провайдеров или объект «провайдер → поля»"
        end
      end

      def named(raw, index)
        where = "#{@source} providers[#{index}]"
        raise InputError, "#{where}: ожидается объект" unless raw.is_a?(Hash)

        Fields.string!(raw, "payment_system", where: where)
      end

      def fields(name, raw)
        where = "#{@source}: провайдер #{name}"
        raise InputError, "#{where}: ожидается объект с полями состояния" unless raw.is_a?(Hash)

        changed = raw.except("payment_system").compact
        changed.to_h { |field, _value| [field.to_sym, value(raw, field, where)] }
      end

      def value(raw, field, where)
        return Fields.number(raw, field, where: where, **NUMERIC.fetch(field)) if NUMERIC.key?(field)
        return Fields.string!(raw, field, where: where) if STRINGS.include?(field)
        return Fields.string_list(raw, field, where: where) if LISTS.include?(field)
        return Fields.boolean(raw, field, where: where) if BOOLEANS.include?(field)

        raise InputError, "#{where}: поле #{field} нельзя обновлять извне (доступны: #{KNOWN.join(", ")})"
      end
    end
  end
end
