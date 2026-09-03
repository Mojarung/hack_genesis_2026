# frozen_string_literal: true

# Фабрики доменных объектов для спеков: разумные дефолты, переопределяемые ключами.
module Builders
  T0 = Time.iso8601("2026-07-30T09:00:00+03:00")
  DATA_DIR = File.expand_path("../../data", __dir__)
  CONFIG_DIR = File.expand_path("../../config", __dir__)

  PROVIDER_DEFAULTS = {
    name: "alpha", status: "active", traffic_percentage: 50, priority: 1,
    limit_amount_min: 1_000, limit_amount_max: 100_000,
    daily_amount_limit: 1_000_000, daily_approved_amount: 0,
    in_progress_count_limit: 10, in_progress_count: 0,
    in_progress_amount_limit: 500_000, in_progress_amount: 0,
    available_requisites: 5, conversion_24h: 0.9, avg_latency_sec: 30,
    banks: [], exclude_banks: false,
    provider_margin_pct: 1.0, merchant_margin_pct: 1.5, allow_negative_agreement: false
  }.freeze

  POLICY_DEFAULTS = {
    "name" => "spec",
    "fallback_provider" => "self",
    "hard_constraints" => PayoutRouter::Constraints::Registry.keys,
    "goals" => { "traffic_share" => 1.0 },
    "tie_breakers" => %w[priority name]
  }.freeze

  def build_provider(**overrides) = PayoutRouter::Domain::Provider.new(**PROVIDER_DEFAULTS, **overrides)

  def build_fallback(name: "self")
    build_provider(name: name, traffic_percentage: 0, priority: 99, limit_amount_min: nil,
                   limit_amount_max: nil, daily_amount_limit: nil, in_progress_count_limit: nil,
                   in_progress_amount_limit: nil, fallback: true, conversion_24h: 0.95, avg_latency_sec: 15)
  end

  def build_operation(id: "op_1", amount: 10_000, bank: "sberbank", at: T0, currency: nil)
    PayoutRouter::Domain::Operation.new(operation_id: id, created_at: at, amount: amount, bank: bank,
                                        currency: currency)
  end

  def build_snapshot(*providers) = PayoutRouter::Domain::Snapshot.new(snapshot_at: T0, providers: providers)

  def build_policy(**overrides)
    PayoutRouter::Inputs::PolicyLoader.from_hash(POLICY_DEFAULTS.merge(overrides.transform_keys(&:to_s)))
  end

  def build_candidate(provider, ledger = nil)
    ledger ||= PayoutRouter::State::Ledger.new(build_snapshot(provider))
    PayoutRouter::Routing::Candidate.new(provider: provider, state: ledger.state(provider.name))
  end

  def route_all(providers:, operations:, policy: build_policy, simulator: PayoutRouter::Simulation::Optimistic.new,
                history: nil)
    snapshot = policy.apply(build_snapshot(*providers))
    PayoutRouter::Routing::BatchRouter.new(snapshot: snapshot, policy: policy, simulator: simulator,
                                           history: history).call(operations)
  end

  def data_path(name) = File.join(DATA_DIR, name)
  def config_path(name) = File.join(CONFIG_DIR, name)

  def default_runner(**overrides)
    PayoutRouter::Runner.new(
      providers_path: data_path("providers.json"), policy_path: config_path("policy.yml"),
      history_path: data_path("operations_history.csv"), **overrides
    )
  end
end
