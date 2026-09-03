# frozen_string_literal: true

module PayoutRouter
  module Analytics
    # Вероятность одобрения заявки провайдером — единая модель для стратегий conversion, bank_affinity,
    # expected_value, бэктеста и сравнения политик. Три уровня, каждый следующий уточняет предыдущий:
    #   1. заявленная conversion_24h из снимка;
    #   2. история провайдера в целом, усаженная к заявленной: (approved + k·declared) / (n + k), k = DECLARED_WEIGHT;
    #   3. история пары провайдер × банк (не меньше MIN_BANK_SAMPLES наблюдений), усаженная к уровню 2.
    # На двух-трёх наблюдениях оценка почти не отходит от приора, на десятках — почти факт.
    # Никакого обучения — только подсчёт частот, который можно проверить руками.
    class ApprovalModel
      Estimate = Data.define(:probability, :source, :samples)

      MIN_BANK_SAMPLES = 5
      DECLARED_WEIGHT = 10
      PROVIDER_WEIGHT = 5

      def initialize(history:, snapshot:)
        @history = history
        @snapshot = snapshot
      end

      # exclude — запись истории, которую не учитываем (leave-one-out).
      def estimate(provider_name, bank, exclude: nil)
        bank_estimate(provider_name, bank, exclude) ||
          provider_estimate(provider_name, exclude) ||
          declared_estimate(provider_name)
      end

      def probability(provider_name, bank, exclude: nil) = estimate(provider_name, bank, exclude: exclude).probability

      private

      def bank_estimate(provider_name, bank, exclude)
        return nil if @history.nil? || bank.nil?

        operations, approved = @history.bank_counts(provider_name, bank, exclude: exclude)
        return nil if operations < MIN_BANK_SAMPLES

        prior = (provider_estimate(provider_name, exclude) || declared_estimate(provider_name)).probability
        Estimate.new(probability: shrink(approved, operations, prior, PROVIDER_WEIGHT),
                     source: "bank_history", samples: operations)
      end

      def provider_estimate(provider_name, exclude)
        return nil if @history.nil?

        operations, approved = @history.provider_counts(provider_name, exclude: exclude)
        return nil if operations.zero?

        prior = declared_estimate(provider_name).probability
        Estimate.new(probability: shrink(approved, operations, prior, DECLARED_WEIGHT),
                     source: "provider_history", samples: operations)
      end

      def declared_estimate(provider_name)
        provider = @snapshot.provider(provider_name)
        Estimate.new(probability: provider&.conversion_24h.to_f, source: "conversion_24h", samples: 0)
      end

      # Доля с приором: (approved + k·prior) / (n + k). Приор стоит k наблюдений.
      def shrink(approved, operations, prior, weight) = (approved + (weight * prior)) / (operations + weight).to_f
    end
  end
end
