# frozen_string_literal: true

module PayoutRouter
  # Выбор среди допустимых кандидатов. Два механизма, оба настраиваются в политике:
  #   weighted — все цели одновременно, итог = взвешенная сумма (CompositeScorer);
  #   chain    — стратегии по очереди: следующая решает, только если предыдущая не смогла (ChainScorer).
  module Scoring
    def self.build(policy:, snapshot:, history: nil)
      if policy.selection.chain?
        ChainScorer.new(policy: policy, snapshot: snapshot, history: history)
      else
        CompositeScorer.new(policy: policy, snapshot: snapshot, history: history)
      end
    end
  end
end
