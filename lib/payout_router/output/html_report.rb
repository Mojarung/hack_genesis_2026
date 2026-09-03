# frozen_string_literal: true

require "erb"
require "fileutils"

module PayoutRouter
  module Output
    # HTML-дашборд одним файлом: распределение, загрузка, исходы, рекомендации и трейс каждого решения.
    # Без внешних библиотек — открывается где угодно, в том числе офлайн.
    class HtmlReport
      TEMPLATE = File.join(__dir__, "..", "templates", "report.html.erb")

      SEVERITY_LABELS = { "critical" => "критично", "warning" => "внимание", "info" => "к сведению" }.freeze

      def initialize(run)
        @run = run
        @report = run.report
      end

      def render
        template = ERB.new(File.read(TEMPLATE, mode: "r:utf-8"), trim_mode: "-")
        template.filename = TEMPLATE
        template.result(binding)
      end

      def write(path)
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, render)
        path
      end

      private

      attr_reader :run, :report

      def h(value) = ERB::Util.html_escape(value.to_s)

      def money(value) = value.nil? ? "—" : "#{value.round.to_s.reverse.scan(/\d{1,3}/).join(" ").reverse} ₽"

      def pct(value) = value.nil? ? "—" : "#{value}%"

      def signed(value) = format("%+.1f", value)

      def bar_width(value) = value.nil? ? 0 : value.to_f.clamp(0, 100).round(1)

      def severity_label(severity) = SEVERITY_LABELS.fetch(severity, severity)

      def decision_mark(decision)
        return "✕" unless decision.routed?

        decision.approved? ? "✓" : "!"
      end

      def reason_text(code) = Routing::Reasons.describe(code)

      def utilization_class(value)
        return "bar-muted" if value.nil?
        return "bar-danger" if value >= 90
        return "bar-warn" if value >= 75

        "bar-ok"
      end
    end
  end
end
