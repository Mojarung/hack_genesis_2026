# frozen_string_literal: true

module PayoutRouter
  module Analytics
    # Поток минимальной стоимости: последовательные кратчайшие пути (SPFA — рёбра с отрицательной
    # стоимостью здесь обычное дело, потому что максимизацию одобрений мы записываем как
    # минимизацию минус-вероятности). Задача крошечная — десяток вершин «банк × провайдер», —
    # поэтому берём самый простой корректный алгоритм, а не самый быстрый.
    class MinCostFlow
      Edge = Struct.new(:to, :capacity, :cost, :twin)

      def initialize(size)
        @graph = Array.new(size) { [] }
      end

      def add(from, to, capacity, cost)
        forward = Edge.new(to, capacity, cost, nil)
        backward = Edge.new(from, 0, -cost, forward)
        forward.twin = backward
        @graph[from] << forward
        @graph[to] << backward
        forward
      end

      # Стоимость потока из source в sink. profitable_only: останавливаться, как только очередной
      # путь перестал уменьшать стоимость — тогда это поток минимальной стоимости, а не обязательно
      # максимальный. Нужно там, где отправить единицу можно, но невыгодно.
      def run(source, sink, profitable_only: false)
        total = 0.0
        loop do
          distance, previous = shortest_paths(source)
          break if distance[sink].infinite?
          break if profitable_only && distance[sink] >= -1e-12

          amount = bottleneck(sink, previous)
          break if amount.zero?

          total += push(sink, previous, amount)
        end
        total
      end

      private

      def shortest_paths(source)
        distance = Array.new(@graph.size, Float::INFINITY)
        previous = Array.new(@graph.size)
        distance[source] = 0.0
        queue = [source]
        queued = Array.new(@graph.size, false)
        queued[source] = true
        until queue.empty?
          node = queue.shift
          queued[node] = false
          relax(node, distance, previous, queue, queued)
        end
        [distance, previous]
      end

      def relax(node, distance, previous, queue, queued)
        @graph[node].each do |edge|
          next if edge.capacity <= 0

          candidate = distance[node] + edge.cost
          next unless candidate < distance[edge.to] - 1e-12

          distance[edge.to] = candidate
          previous[edge.to] = [node, edge]
          next if queued[edge.to]

          queued[edge.to] = true
          queue << edge.to
        end
      end

      def bottleneck(sink, previous)
        amount = Float::INFINITY
        node = sink
        while (step = previous[node])
          amount = [amount, step[1].capacity].min
          node = step[0]
        end
        amount.infinite? ? 0 : amount
      end

      def push(sink, previous, amount)
        cost = 0.0
        node = sink
        while (step = previous[node])
          edge = step[1]
          edge.capacity -= amount
          edge.twin.capacity += amount
          cost += edge.cost * amount
          node = step[0]
        end
        cost
      end
    end
  end
end
