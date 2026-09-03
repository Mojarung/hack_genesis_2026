# frozen_string_literal: true

require "csv"

module PayoutRouter
  module Inputs
    # operations_history.csv → [Domain::HistoryRecord]. Читаем потоково — файл может быть большим.
    class HistoryLoader
      REQUIRED_COLUMNS = %w[operation_id amount bank payment_system status].freeze

      def self.load(path) = new(path).call

      def initialize(path)
        @path = path.to_s
      end

      def call
        raise InputError, "файл истории не найден: #{@path}" unless File.file?(@path)

        records = []
        CSV.foreach(@path, headers: true, encoding: "bom|utf-8").with_index(2) do |row, line|
          check_columns!(row.headers) if records.empty?
          records << build(row, line)
        end
        records
      rescue CSV::MalformedCSVError => e
        raise InputError, "#{@path}: невалидный CSV — #{e.message}"
      end

      private

      def check_columns!(headers)
        missing = REQUIRED_COLUMNS - headers.compact
        return if missing.empty?

        raise InputError, "#{@path}: в заголовке нет колонок #{missing.join(", ")}"
      end

      def build(row, line)
        where = "#{@path}:#{line}"
        status = row["status"].to_s.strip.downcase
        unless Domain::HistoryRecord::STATUSES.include?(status)
          raise InputError, "#{where}: status должен быть одним из #{Domain::HistoryRecord::STATUSES.join("/")}"
        end

        Domain::HistoryRecord.new(
          operation_id: presence(row["operation_id"]) || raise(InputError, "#{where}: пустой operation_id"),
          created_at: parse_time(row["created_at"], where),
          amount: parse_amount(row["amount"], where),
          bank: presence(row["bank"])&.downcase,
          card_brand: presence(row["card_brand"]),
          provider: presence(row["payment_system"]) || raise(InputError, "#{where}: пустой payment_system"),
          status: status,
          latency_sec: presence(row["latency_sec"])&.to_i
        )
      end

      def presence(value)
        stripped = value.to_s.strip
        stripped.empty? ? nil : stripped
      end

      def parse_time(value, where)
        return nil if presence(value).nil?

        Time.iso8601(value.strip)
      rescue ArgumentError
        raise InputError, "#{where}: created_at должен быть датой ISO 8601"
      end

      def parse_amount(value, where)
        amount = Float(value.to_s.strip, exception: false)
        raise InputError, "#{where}: amount должен быть положительным числом" if amount.nil? || amount <= 0

        amount == amount.floor ? amount.to_i : amount
      end
    end
  end
end
