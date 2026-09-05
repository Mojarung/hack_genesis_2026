# frozen_string_literal: true

module PayoutRouter
  module Search
    # Полный перебор конфигураций политики через настоящий роутер. Никакой модели поверх модели:
    # каждая точка — это прогон всех очередей батареи, поэтому найденное нельзя списать
    # на артефакт аппроксимации. Дорого (десятки миллисекунд на конфигурацию), зато честно.
    class Engine
      REFINE_STEP = 0.05
      REFINE_PASSES = 3

      def initialize(battery:, policy:, random_samples: 2000, seed: 1, shard: nil, shards: 1,
                     grid_goals: Space::GRID_GOALS)
        @battery = battery
        @policy = policy
        @random_samples = random_samples
        @grid_goals = grid_goals
        @seed = seed
        @shard = shard
        @shards = shards
        @evaluations = 0
      end

      def call
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        front = Front.new
        bests = {}
        structural = {}
        base = nil
        log = { front: front, bests: bests }
        variants.each do |label, variant|
          local = sweep(label, variant, log)
          base ||= local[:base]
          structural[label] = local[:best]
        end
        finish(started, base, front, bests, structural)
      end

      private

      def variants
        all = Space.structural(@policy)
        return all if @shard.nil?

        all.each_with_index.select { |_pair, index| index % @shards == @shard }.map(&:first)
      end

      def finish(started, base, front, bests, structural)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        candidates = front.candidates
        dominating = base.nil? ? 0 : candidates.count { |item| item.metrics.dominates?(base.metrics) }
        Outcome.new(evaluations: @evaluations, elapsed_sec: elapsed, base: base, front: candidates,
                    bests: bests, structural: structural, dominating_base: dominating)
      end

      def sweep(label, variant, log)
        base = nil
        local_best = nil
        space = Space.new(policy: @policy, random_samples: @random_samples, seed: @seed, grid_goals: @grid_goals)
        space.each do |origin, goals|
          candidate = record(log, evaluate(label, variant, origin, goals))
          base ||= candidate if origin == "base"
          local_best = candidate if local_best.nil? || better?(candidate, local_best)
        end
        { base: base, best: refine(label, variant, local_best, log) }
      end

      # Кандидата отдаём и во фронт, и в лидеров по метрикам — оба накопителя едут вместе.
      def record(log, candidate)
        log[:front].add?(candidate)
        track(log[:bests], candidate)
        candidate
      end

      def better?(candidate, other) = candidate.metrics.scalar < other.metrics.scalar

      def track(bests, candidate)
        Outcome::OBJECTIVES.each do |key, measure|
          kept = bests[key]
          bests[key] = candidate if kept.nil? || measure.call(candidate.metrics) < measure.call(kept.metrics)
        end
      end

      def evaluate(label, variant, origin, goals)
        @evaluations += 1
        Candidate.new(origin: origin, structural: label, goals: goals,
                      metrics: @battery.call(variant.with_goals(goals)))
      end

      # Покоординатная доводка лучшей скалярной точки: ±шаг по каждой цели, пока есть улучшение.
      def refine(label, variant, candidate, log)
        REFINE_PASSES.times do
          improved = false
          candidate.goals.each_key do |goal|
            better = neighbour(label, variant, candidate, goal, log)
            next if better.nil?

            candidate = better
            improved = true
          end
          break unless improved
        end
        candidate.with(origin: "#{candidate.origin}+refined")
      end

      def neighbour(label, variant, candidate, goal, log)
        probes = [REFINE_STEP, -REFINE_STEP].filter_map do |delta|
          goals = shifted(candidate.goals, goal, delta)
          next if goals.nil?

          record(log, evaluate(label, variant, candidate.origin, goals))
        end
        probes.select { |probe| better?(probe, candidate) }.min_by { |probe| probe.metrics.scalar }
      end

      def shifted(goals, goal, delta)
        weight = (goals[goal].to_f + delta).round(3)
        return nil if weight.negative?

        shifted = goals.merge(goal => weight)
        shifted.values.sum.zero? ? nil : shifted
      end
    end
  end
end
