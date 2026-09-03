# frozen_string_literal: true

module PayoutRouter
  module State
    # Очередь отложенных ответов провайдеров (min-heap по времени ответа).
    # Позволяет освобождать in-progress «когда ответ пришёл», а не сразу после отправки.
    class SettlementQueue
      Entry = Data.define(:due, :sequence, :payload)

      def initialize
        @heap = []
        @sequence = 0
      end

      def size = @heap.size
      def empty? = @heap.empty?

      def push(due, payload)
        @heap << Entry.new(due: due, sequence: @sequence += 1, payload: payload)
        sift_up(@heap.size - 1)
      end

      # Снять и вернуть ближайшую запись, если её время наступило; иначе nil.
      def pop_due(now)
        return nil if @heap.empty? || @heap.first.due > now

        pop
      end

      def pop
        return nil if @heap.empty?

        top = @heap.first
        last = @heap.pop
        unless @heap.empty?
          @heap[0] = last
          sift_down(0)
        end
        top.payload
      end

      private

      def before?(left, right) = left.due < right.due || (left.due == right.due && left.sequence < right.sequence)

      def sift_up(index)
        while index.positive?
          parent = (index - 1) / 2
          break unless before?(@heap[index], @heap[parent])

          @heap[index], @heap[parent] = @heap[parent], @heap[index]
          index = parent
        end
      end

      def sift_down(index)
        size = @heap.size
        loop do
          left = (2 * index) + 1
          right = left + 1
          smallest = index
          smallest = left if left < size && before?(@heap[left], @heap[smallest])
          smallest = right if right < size && before?(@heap[right], @heap[smallest])
          break if smallest == index

          @heap[index], @heap[smallest] = @heap[smallest], @heap[index]
          index = smallest
        end
      end
    end
  end
end
