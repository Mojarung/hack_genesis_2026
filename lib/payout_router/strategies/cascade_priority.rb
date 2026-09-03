# frozen_string_literal: true

module PayoutRouter
  module Strategies
    # Стратегия 3: очередь в каскаде. Первый по priority получает 1.0, последний — 0.0.
    # С весом 1.0 и остальными 0 превращается в классический каскад «сначала vipay, потом payflow…».
    class CascadePriority < Base
      def initialize(policy:, snapshot:, history: nil)
        super
        ordered = snapshot.external.sort_by { |provider| [provider.priority, provider.name] }
        @rank = ordered.each_with_index.to_h { |provider, index| [provider.name, index] }
        @last = [ordered.size - 1, 1].max
      end

      def evaluate(candidate, _context)
        rank = @rank.fetch(candidate.name, @last)
        signal(1.0 - (rank.to_f / @last), "priority #{candidate.provider.priority} (#{rank + 1} of #{@rank.size})")
      end
    end
  end
end
