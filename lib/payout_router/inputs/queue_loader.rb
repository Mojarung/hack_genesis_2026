# frozen_string_literal: true

module PayoutRouter
  module Inputs
    # operations_queue.json → [Domain::Operation].
    # Заявке без created_at назначаем default_time + порядковый номер в секундах —
    # порядок обработки сохраняется, а роутер не падает на неполных данных.
    class QueueLoader
      def self.load(path, default_time: nil) = new(JSONFile.read(path), source: path, default_time: default_time).call

      def initialize(document, source: "operations_queue.json", default_time: nil)
        @document = document
        @source = source
        @default_time = default_time || Time.now
      end

      def call
        raise InputError, "#{@source}: ожидается массив заявок" unless @document.is_a?(Array)

        seen = Set.new
        @document.each_with_index.map do |raw, index|
          operation = build(raw, index)
          unless seen.add?(operation.operation_id)
            raise InputError, "#{@source}: operation_id #{operation.operation_id} повторяется"
          end

          operation
        end
      end

      private

      def build(raw, index)
        raise InputError, "#{@source} [#{index}]: ожидается объект" unless raw.is_a?(Hash)

        id = Fields.string!(raw, "operation_id", where: "#{@source} [#{index}]")
        where = "#{@source} заявка #{id}"
        Domain::Operation.new(
          operation_id: id,
          created_at: Fields.time(raw, "created_at", where: where) || (@default_time + index),
          amount: Fields.amount!(raw, "amount", where: where),
          bank: Fields.string(raw, "bank", where: where)&.downcase,
          card_brand: Fields.string(raw, "card_brand", where: where),
          payout_requisite: raw["payout_requisite"]
        )
      end
    end
  end
end
