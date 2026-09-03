# frozen_string_literal: true

module PayoutRouter
  module Constraints
    # Hard-constraint: отвечает «можно ли вообще отдать заявку этому провайдеру».
    # Новое правило = новый класс-наследник + ключ в политике (hard_constraints).
    class Base
      # Ключ правила в политике: ProviderActive → "provider_active".
      def self.key = @key ||= name.split("::").last.gsub(/([a-z\d])([A-Z])/, "\\1_\\2").downcase

      def key = self.class.key

      # candidate — Routing::Candidate, operation — Domain::Operation, now — Time.
      def call(_candidate, _operation, _now) = raise(NotImplementedError, "#{self.class}#call")

      private

      def pass = Verdict::PASS
      def violation(reason, details) = Verdict.violation(reason, details)
    end
  end
end
