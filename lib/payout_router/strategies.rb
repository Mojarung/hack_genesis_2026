# frozen_string_literal: true

module PayoutRouter
  # Soft-goals. Три источника стратегий:
  #   встроенные (Registry::BUILTIN), плагины из policy.yml → plugins (наследники Base, регистрируются
  #   автоматически) и декларативные цели из policy.yml → custom_goals (Custom::*), без кода.
  module Strategies
    def self.instantiate(key, policy:, snapshot:, history: nil)
      definition = policy.custom_goals[key]
      return Custom.build(key, definition, policy: policy, snapshot: snapshot, history: history) if definition

      Registry.fetch(key).new(policy: policy, snapshot: snapshot, history: history)
    end
  end
end
