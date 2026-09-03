# frozen_string_literal: true

module PayoutRouter
  module Strategies
    # Оценка кандидата одной целью: число 0..1 и короткое пояснение для трейса.
    class Signal < Data.define(:score, :note)
    end
  end
end
