# frozen_string_literal: true

module PayoutRouter
  module Strategies
    # Стратегия 2: целевая доля по объёму (рубли). База — дневной оборот из снимка
    # плюс заявки сессии, так что перекос, накопленный до старта, тоже выравнивается.
    class VolumeShare < Base
      def evaluate(candidate, context)
        target = candidate.provider.volume_target_pct.to_f
        actual = context.ledger.volume_share_pct(candidate.state)
        deficit = target - actual
        signal(0.5 + (deficit / 100.0), "volume share #{pct(actual)} vs target #{pct(target)} (#{signed(deficit)} pp)")
      end
    end
  end
end
