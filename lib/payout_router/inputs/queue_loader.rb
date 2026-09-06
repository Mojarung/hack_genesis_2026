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
      MODES = %i[fail skip].freeze

      # Заявка, которую не удалось разобрать: с чем именно и на каком месте в файле.
      Rejected = Data.define(:index, :operation_id, :message)

      attr_reader :rejected

      def self.load(path, default_time: nil, on_invalid: :fail)
        new(JSONFile.read(path), source: path, default_time: default_time, on_invalid: on_invalid).call
      end

      # on_invalid: :fail — любая неразобранная заявка останавливает прогон с адресной ошибкой.
      # Это разумно по умолчанию: молча отроутить часть очереди хуже, чем громко не отроутить ничего.
      # :skip — заявка уходит в карантин (rejected), остальные обрабатываются. Страховка на сдачу:
      # одна неожиданная строка в тестовой очереди не должна оставить нас вообще без файла решений.
      def initialize(document, source: "operations_queue.json", default_time: nil, on_invalid: :fail)
        @on_invalid = on_invalid.to_sym
        raise InputError, "неизвестный режим on_invalid: #{on_invalid}" unless MODES.include?(@on_invalid)

        @document = document
        @source = source
        @default_time = default_time
        @rejected = []
      end

      def call
        raise InputError, "#{@source}: ожидается массив заявок" unless @document.is_a?(Array)

        base = @default_time || earliest_created_at || EPOCH
        seen = Set.new
        @rejected = []
        @document.each_with_index.filter_map { |raw, index| load_one(raw, index, base, seen) }
      end

      private

      def load_one(raw, index, base, seen)
        operation = build(raw, index, base)
        unless seen.add?(operation.operation_id)
          raise InputError, "#{@source}: operation_id #{operation.operation_id} повторяется"
        end

        operation
      rescue InputError => e
        if @on_invalid == :fail
          e.skippable = true
          raise
        end

        @rejected << Rejected.new(index: index, operation_id: raw.is_a?(Hash) ? raw["operation_id"] : nil,
                                  message: e.message)
        nil
      end

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
