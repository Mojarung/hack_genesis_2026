# frozen_string_literal: true

module PayoutRouter
  module Scoring
    # Всё, что нужно стратегиям для оценки кандидата: заявка, леджер (доли, загрузка) и время.
    class Context < Data.define(:operation, :ledger, :now)
    end
  end
end
