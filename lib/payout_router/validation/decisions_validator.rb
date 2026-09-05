# frozen_string_literal: true

module PayoutRouter
  module Validation
    # Проверка файла решений (сырой JSON) теми же критериями, что у автопроверки организаторов:
    # структура, покрытие очереди, допустимость выбранного провайдера по hard-правилам от снимка,
    # эталонные кейсы. Плюс наш инвариант: ровно один selected, и он совпадает с selected_provider.
    class DecisionsValidator
      Check = Data.define(:status, :message) do
        def pass? = status == :pass
        def fail? = status == :fail
        def warn? = status == :warn
      end

      Result = Data.define(:checks) do
        def passed = checks.count(&:pass?)
        def failed = checks.count(&:fail?)
        def warnings = checks.count(&:warn?)
        def ok? = failed.zero?
      end

      REQUIRED_FIELDS = %w[operation_id selected_provider attempts].freeze
      ATTEMPT_FIELDS = %w[provider decision reason].freeze
      DECISIONS = [Routing::Attempt::SELECTED, Routing::Attempt::SKIPPED].freeze

      def initialize(decisions:, operations:, snapshot:, policy:, reference: nil, quarantined: [])
        raise InputError, "файл решений должен содержать массив" unless decisions.is_a?(Array)

        @decisions = decisions
        @operations = operations
        @snapshot = snapshot
        @policy = policy
        @reference = reference
        @quarantined = quarantined
        @by_id = decisions.grep(Hash).to_h { |decision| [decision["operation_id"], decision] }
      end

      def call
        checks = []
        coverage(checks)
        structure(checks)
        consistency(checks)
        eligibility(checks)
        reference_cases(checks) if @reference
        Result.new(checks: checks)
      end

      private

      def coverage(checks)
        queue_ids = @operations.map(&:operation_id)
        missing = queue_ids - @by_id.keys
        extra = @by_id.keys - queue_ids
        checks << if missing.empty?
                    pass("все #{queue_ids.size} заявок из очереди покрыты")
                  else
                    fail!("нет решений для: #{missing.join(", ")}")
                  end
        checks << warn("лишние operation_id: #{extra.join(", ")}") unless extra.empty?
        quarantine(checks)
      end

      # Карантин (on_invalid: skip) уменьшает и очередь, и файл решений одновременно, поэтому
      # покрытие сходится и молчит. Заявок в сдаваемом файле при этом нет — это надо видеть.
      def quarantine(checks)
        return if @quarantined.empty?

        ids = @quarantined.map { |rejected| rejected.operation_id || "позиция #{rejected.index}" }
        checks << warn("в карантине #{ids.size} заявок, решений по ним нет: #{ids.join(", ")}")
      end

      def structure(checks)
        errors = @decisions.flat_map { |decision| structure_errors(decision) }
        checks << (errors.empty? ? pass("структура JSON корректна") : fail!("ошибки структуры: #{errors.join("; ")}"))
      end

      def structure_errors(decision)
        return ["элемент не объект: #{decision.inspect[0, 40]}"] unless decision.is_a?(Hash)

        id = decision["operation_id"] || "?"
        missing = REQUIRED_FIELDS.reject { |field| decision.key?(field) }.map { |field| "#{id}: нет поля #{field}" }
        attempts = Array(decision["attempts"])
        missing + attempts.each_with_index.flat_map { |attempt, index| attempt_errors(id, attempt, index) }
      end

      def attempt_errors(id, attempt, index)
        return ["#{id}: attempts[#{index}] не объект"] unless attempt.is_a?(Hash)

        prefix = "#{id}: attempts[#{index}]"
        errors = ATTEMPT_FIELDS.reject { |field| attempt.key?(field) }.map { |field| "#{prefix} без #{field}" }
        errors << "#{prefix} decision должен быть selected/skipped" unless DECISIONS.include?(attempt["decision"])
        errors
      end

      # Ровно один selected, и это selected_provider (либо ни одного, если заявка не маршрутизирована).
      def consistency(checks)
        problems = @by_id.filter_map { |id, decision| consistency_problem(id, decision) }
        checks << (problems.empty? ? pass("трейс попыток согласован с selected_provider") : fail!(problems.join("; ")))
      end

      def consistency_problem(id, decision)
        selected = Array(decision["attempts"]).grep(Hash).select { |attempt| attempt["decision"] == "selected" }
        provider = decision["selected_provider"]
        return "#{id}: selected-попыток #{selected.size}, ожидалась одна" if selected.size > 1
        return "#{id}: selected_provider задан, но selected-попытки нет" if selected.empty? && provider
        return nil if selected.empty? || selected.first["provider"] == provider

        "#{id}: selected_provider #{provider} не совпадает с selected-попыткой #{selected.first["provider"]}"
      end

      # Допустимость считаем «статически» — от снимка, без накопленного состояния (как валидатор жюри).
      def eligibility(checks)
        pipeline = Constraints::Pipeline.new(@policy.hard_constraints)
        @operations.each do |operation|
          decision = @by_id[operation.operation_id]
          next unless decision

          checks << eligibility_check(operation, decision["selected_provider"], eligible_names(pipeline, operation))
        end
      end

      # selected_provider: null валидатор организаторов считает ошибкой (nil не входит в список допустимых) — мы тоже.
      def eligibility_check(operation, selected, eligible)
        id = operation.operation_id
        if selected.nil?
          return fail!("#{id}: заявка не маршрутизирована, selected_provider пуст (допустимые: #{eligible.join(", ")})")
        end
        return pass("#{id}: #{selected} допустим [#{eligible.join(", ")}]") if eligible.include?(selected)

        fail!("#{id}: #{selected} НЕ допустим, допустимые: [#{eligible.join(", ")}]")
      end

      def eligible_names(pipeline, operation)
        ledger = State::Ledger.new(@snapshot)
        @snapshot.providers.filter_map do |provider|
          candidate = Routing::Candidate.new(state: ledger.state(provider.name))
          provider.name if pipeline.evaluate(candidate, operation, operation.created_at).eligible?
        end
      end

      def reference_cases(checks)
        Array(@reference["deterministic_cases"]).each do |kase|
          decision = @by_id[kase["operation_id"]]
          next unless decision

          checks << reference_check(kase, decision["selected_provider"])
        end
        reference_skips(checks)
      end

      def reference_check(kase, selected)
        id = kase["operation_id"]
        expected = kase["required_provider"]
        return pass("#{id}: эталон #{expected} совпал") if selected == expected

        fail!("#{id}: выбран #{selected}, эталон #{expected} (#{kase["reason"]})")
      end

      def reference_skips(checks)
        (@reference["skip_reasons_expected"] || {}).each do |id, skips|
          decision = @by_id[id]
          next unless decision

          skips.each { |provider, reason| checks << skip_check(id, decision, provider, reason) }
        end
      end

      def skip_check(id, decision, provider, expected_reason)
        attempt = Array(decision["attempts"]).grep(Hash).find { |a| a["provider"] == provider }
        return warn("#{id}: нет попытки для #{provider} (ожидался skip #{expected_reason})") if attempt.nil?
        return warn("#{id}: #{provider} не skipped (ожидался #{expected_reason})") if attempt["decision"] != "skipped"

        pass("#{id}: #{provider} skipped (#{attempt["reason"]})")
      end

      def pass(message) = Check.new(status: :pass, message: message)
      def fail!(message) = Check.new(status: :fail, message: message)
      def warn(message) = Check.new(status: :warn, message: message)
    end
  end
end
