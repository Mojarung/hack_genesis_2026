# frozen_string_literal: true

module PayoutRouter
  module Output
    # Человекочитаемый разбор одного решения: кого рассмотрели, кого выбрали и почему.
    # only — показать только попытку конкретного провайдера («почему не payflow?»).
    class Explanation
      def initialize(decision, verbose: false, only: nil)
        @decision = decision
        @verbose = verbose
        @only = only
      end

      def lines
        operation = @decision.operation
        header = "#{operation.operation_id} · #{money(operation.amount)} · #{operation.bank || "банк не указан"}" \
                 "#{" · #{operation.created_at.strftime("%Y-%m-%d %H:%M:%S")}" if operation.created_at}"
        [header, *attempts.flat_map { |attempt| attempt_lines(attempt) }, "", outcome_line]
      end

      private

      def attempts
        return @decision.attempts if @only.nil?

        selected = @decision.attempts.select { |attempt| attempt.provider == @only }
        selected.empty? ? [] : selected
      end

      def attempt_lines(attempt)
        mark = attempt.selected? ? "+" : "-"
        head = format("  %s %-14s %-32s %s", mark, attempt.provider, attempt.reason, Routing::Reasons.describe(attempt.reason))
        lines = [head]
        lines << "      #{attempt.details}" if attempt.details
        show_breakdown = attempt.breakdown && (attempt.selected? || attempt.dispatched? || @verbose || @only)
        lines.concat(breakdown_lines(attempt.breakdown)) if show_breakdown
        lines
      end

      def breakdown_lines(breakdown)
        breakdown.map do |goal, component|
          format("      %-18s %.3f × %.2f = %.4f   %s", goal, component["score"], component["weight"],
                 component["weighted"], component["note"])
        end
      end

      def outcome_line
        return "  => #{@only}: не рассматривался для этой заявки" if @only && attempts.empty?
        unless @decision.routed?
          return "  => заявка не маршрутизирована: #{Routing::Reasons.describe(@decision.reason)}"
        end

        fallback = @decision.fallback_used ? " (fallback на self-provider)" : ""
        retries = @decision.retries.positive? ? ", после #{@decision.retries} неудачных попыток" : ""
        "  => #{@decision.selected_provider}: #{@decision.simulated_result} " \
          "за #{@decision.latency_sec} с#{fallback}#{retries}"
      end

      def money(value) = "#{value.round.to_s.reverse.scan(/\d{1,3}/).join(" ").reverse} ₽"
    end
  end
end
