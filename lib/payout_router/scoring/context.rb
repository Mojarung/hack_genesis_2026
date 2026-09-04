# frozen_string_literal: true

module PayoutRouter
  module Scoring
    # Всё, что нужно стратегиям для оценки кандидата: заявка, леджер (доли, загрузка) и время.
    # pool — допустимые кандидаты этой заявки: цели по долям пересчитывают на них целевые проценты,
    # когда политика просит считать цель достижимой (share_targets: attainable). Без пула
    # (например, в спеках на одну стратегию) цели работают по абсолютным процентам из снимка.
    class Context < Data.define(:operation, :ledger, :now, :pool)
      def initialize(pool: nil, **rest) = super

      # Суммарная целевая доля допустимых кандидатов — база для перенормировки.
      # yield даёт цель одного кандидата: у долей по количеству и по объёму они разные.
      def pool_target_sum(&) = pool&.sum(&)
    end
  end
end
