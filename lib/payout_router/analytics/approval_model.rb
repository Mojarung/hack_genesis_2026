# frozen_string_literal: true

module PayoutRouter
  module Analytics
    # Вероятность одобрения заявки провайдером — единая модель для стратегии bank_affinity,
    # бэктеста и сравнения политик. Источники по убыванию точности:
    #   1. история пары провайдер × банк (сглаженная по Лапласу, не меньше MIN_BANK_SAMPLES наблюдений);
    #   2. история провайдера в целом;
    #   3. заявленная conversion_24h из снимка.
    # Никакого обучения — только подсчёт частот, который можно проверить руками.
    class ApprovalModel
      Estimate = Data.define(:probability, :source, :samples)

      MIN_BANK_SAMPLES = 2

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

        samples = @history.bank_samples(provider_name, bank)
        samples -= 1 if exclude && exclude.provider == provider_name && exclude.bank == bank
        return nil if samples < MIN_BANK_SAMPLES

        Estimate.new(probability: @history.bank_conversion(provider_name, bank, exclude: exclude),
                     source: "bank_history", samples: samples)
      end

      def provider_estimate(provider_name, exclude)
        return nil if @history.nil?

        probability = @history.smoothed_conversion(provider_name, exclude: exclude)
        return nil if probability.nil?

        samples = @history.for(provider_name).operations - (exclude&.provider == provider_name ? 1 : 0)
        Estimate.new(probability: probability, source: "provider_history", samples: samples)
      end

      def declared_estimate(provider_name)
        provider = @snapshot.provider(provider_name)
        Estimate.new(probability: provider&.conversion_24h.to_f, source: "conversion_24h", samples: 0)
      end
    end
  end
end
