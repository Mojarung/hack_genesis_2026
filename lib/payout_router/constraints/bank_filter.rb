# frozen_string_literal: true

module PayoutRouter
  module Constraints
    class BankFilter < Base
      def call(candidate, operation, _now)
        provider = candidate.provider
        return pass unless provider.bank_filter?

        bank = operation.bank
        return violation(Routing::Reasons::BANK_UNKNOWN, "bank is missing, provider filters by bank") if bank.nil?
        return pass if provider.bank_allowed?(bank)

        list = provider.banks.join(", ")
        if provider.exclude_banks
          violation(Routing::Reasons::BANK_EXCLUDED, "#{bank} in exclude_banks [#{list}]")
        else
          violation(Routing::Reasons::BANK_NOT_IN_LIST, "#{bank} not in banks [#{list}]")
        end
      end
    end
  end
end
