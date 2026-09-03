# frozen_string_literal: true

module PayoutRouter
  module Inputs
    # operations_queue.json → [Domain::Operation].
    # Заявке без created_at назначаем базовое время + порядковый номер в секундах — порядок обработки
    # сохраняется, а роутер не падает на неполных данных. База — default_time (снимок провайдеров),
    # иначе самое раннее created_at очереди, иначе фиксированная эпоха: результат не должен
    # зависеть от момента запуска.
    class QueueLoader
      EPOCH = Time.utc(2026, 1, 1)

      def self.load(path, default_time: nil) = new(JSONFile.read(path), source: path, default_time: default_time).call

      def initialize(document, source: "operations_queue.json", default_time: nil)
        @document = document
        @source = source
        @default_time = default_time
      end

      def call
        raise InputError, "#{@source}: ожидается массив заявок" unless @document.is_a?(Array)

        base = @default_time || earliest_created_at || EPOCH
        seen = Set.new
        @document.each_with_index.map do |raw, index|
          operation = build(raw, index, base)
          unless seen.add?(operation.operation_id)
            raise InputError, "#{@source}: operation_id #{operation.operation_id} повторяется"
          end

          operation
        end
      end

      private

      def build(raw, index, base)
        raise InputError, "#{@source} [#{index}]: ожидается объект" unless raw.is_a?(Hash)

        id = Fields.identifier!(raw, "operation_id", where: "#{@source} [#{index}]")
        where = "#{@source} заявка #{id}"
        Domain::Operation.new(
          operation_id: id,
          created_at: Fields.time(raw, "created_at", where: where) || (base + index),
          amount: Fields.amount!(raw, "amount", where: where),
          currency: Fields.string(raw, "currency", where: where)&.upcase,
          bank: Fields.string(raw, "bank", where: where)&.downcase,
          card_brand: Fields.string(raw, "card_brand", where: where),
          payout_requisite: raw["payout_requisite"]
        )
      end

      def earliest_created_at
        @document.grep(Hash).filter_map do |raw|
          Fields.time(raw, "created_at", where: @source)
        rescue InputError
          nil
        end.min
      end
    end
  end
end
