# frozen_string_literal: true

require "webrick"

module PayoutRouter
  # HTTP-сервис поверх роутера: заявка приходит в POST /route, решение уходит сразу,
  # состояние провайдеров (оборот, in-progress, интенсивность, предохранитель) живёт между запросами.
  # GET /report — отчёт по накопленным решениям, GET /metrics — метрики в формате Prometheus.
  class Server
    # Состояние сервиса: один леджер, один роутер, накопленные решения. Потокобезопасно.
    class Service
      attr_reader :started_at

      def initialize(runner)
        @runner = runner
        @snapshot = runner.snapshot
        @policy = runner.policy
        @mutex = Mutex.new
        reset!
      end

      def reset!
        @mutex.synchronize do
          @ledger = State::Ledger.new(@snapshot, circuit_breaker: @policy.circuit_breaker,
                                                 hold_timeouts: @policy.simulation.hold_timeouts?)
          simulator = Simulation.build(@runner.simulation, history_stats: @runner.history_stats)
          @router = Routing::Router.new(snapshot: @snapshot, policy: @policy, ledger: @ledger, simulator: simulator,
                                        history: @runner.history_stats)
          @decisions = []
          @started_at = Time.now
        end
      end

      # Заявка в формате operations_queue.json → решение. Без created_at берём текущее время.
      # Конверт { "operation": {...}, "providers": [...] } позволяет прислать вместе с заявкой свежее
      # состояние провайдеров: тогда источник истины — вызывающая система, а не наши счётчики.
      # Без конверта роутер ведёт состояние сам — обе схемы эксперты назвали допустимыми.
      def route(payload)
        unless payload.is_a?(Hash)
          raise InputError, "тело запроса должно быть заявкой или конвертом { operation, providers }"
        end

        raw, updates = unwrap(payload)
        operation = Inputs::QueueLoader.new([raw], source: "request", default_time: Time.now).call.first
        @mutex.synchronize do
          @ledger.sync!(updates) unless updates.empty?
          decision = @router.route(operation)
          @decisions << decision
          decision
        end
      end

      def decisions_count = @mutex.synchronize { @decisions.size }

      def report
        @mutex.synchronize do
          Analytics::ReportBuilder.new(decisions: @decisions.dup, ledger: @ledger, snapshot: @snapshot, policy: @policy,
                                       history_stats: @runner.history_stats, simulation: @runner.simulation).build
        end
      end

      def state
        @mutex.synchronize do
          stats = Analytics::RoutingStats.new(decisions: @decisions, ledger: @ledger, snapshot: @snapshot)
          { "decisions" => @decisions.size, "started_at" => @started_at.iso8601, "policy" => @policy.name,
            "pending_settlements" => @ledger.pending_settlements, "providers" => stats.utilization }
        end
      end

      # Prometheus text exposition format: счётчики решений и состояние каждого провайдера.
      def metrics
        @mutex.synchronize do
          lines = ["# HELP payout_router_uptime_seconds Секунд с момента старта",
                   "# TYPE payout_router_uptime_seconds gauge",
                   "payout_router_uptime_seconds #{(Time.now - @started_at).round(1)}"]
          lines.concat(decision_metrics)
          lines.concat(provider_metrics)
          "#{lines.join("\n")}\n"
        end
      end

      private

      # Заявка приходит либо сама по себе, либо в конверте вместе со снимком состояния провайдеров.
      def unwrap(payload)
        return [payload, {}] unless payload.key?("operation")
        raise InputError, "request: operation должен быть объектом заявки" unless payload["operation"].is_a?(Hash)

        [payload["operation"], Inputs::StateUpdate.parse(payload["providers"], source: "request")]
      end

      def decision_metrics
        counts = @decisions.group_by { |decision| [decision.selected_provider || "none", decision.simulated_result] }
        ["# HELP payout_router_decisions_total Решений по провайдеру и исходу",
         "# TYPE payout_router_decisions_total counter"] +
          counts.map do |(provider, result), list|
            "payout_router_decisions_total{provider=\"#{provider}\",result=\"#{result}\"} #{list.size}"
          end
      end

      def provider_metrics
        gauges = {
          "daily_approved_amount" => lambda(&:daily_approved_amount),
          "in_progress_count" => lambda(&:in_progress_count),
          "in_progress_amount" => lambda(&:in_progress_amount),
          "available_requisites" => lambda(&:available_requisites),
          "circuit_trips" => lambda(&:circuit_trips),
          "circuit_open" => ->(state) { state.circuit_open?(Time.now) ? 1 : 0 }
        }
        gauges.flat_map do |name, reader|
          ["# TYPE payout_router_provider_#{name} gauge"] +
            @ledger.states.map do |provider, state|
              "payout_router_provider_#{name}{provider=\"#{provider}\"} #{reader.call(state)}"
            end
        end
      end
    end

    JSON_TYPE = "application/json; charset=utf-8"

    attr_reader :service

    def initialize(service, host: "127.0.0.1", port: 8080, logger: nil)
      @service = service
      @server = WEBrick::HTTPServer.new(BindAddress: host, Port: port, Logger: logger || WEBrick::Log.new(File::NULL),
                                        AccessLog: [])
      mount
    end

    def port = @server.listeners.first.addr[1]
    def running? = @server.status == :Running
    def start = @server.start
    def stop = @server.shutdown

    private

    def mount
      @server.mount_proc("/health") do |_req, res|
        json(res, { "status" => "ok", "decisions" => @service.decisions_count })
      end
      @server.mount_proc("/route") { |req, res| handle(req, res) { route(req, res) } }
      @server.mount_proc("/report") { |_req, res| json(res, @service.report) }
      @server.mount_proc("/state") { |_req, res| json(res, @service.state) }
      @server.mount_proc("/metrics") { |_req, res| text(res, @service.metrics) }
      @server.mount_proc("/reset") do |req, res|
        handle(req, res) do
          @service.reset!
          json(res, { "status" => "reset" })
        end
      end
    end

    def route(req, res)
      payload = JSON.parse(req.body.to_s)
      if payload.is_a?(Array)
        json(res, payload.map { |item| @service.route(item).serialize })
      else
        json(res, @service.route(payload).serialize)
      end
    end

    def handle(req, res)
      return json(res, { "error" => "нужен POST" }, status: 405) unless req.request_method == "POST"

      yield
    rescue JSON::ParserError => e
      json(res, { "error" => "невалидный JSON: #{e.message[0, 100]}" }, status: 400)
    rescue PayoutRouter::Error => e
      json(res, { "error" => e.message }, status: 400)
    end

    def json(res, data, status: 200)
      res.status = status
      res["Content-Type"] = JSON_TYPE
      res.body = JSON.generate(data)
    end

    def text(res, body)
      res["Content-Type"] = "text/plain; version=0.0.4; charset=utf-8"
      res.body = body
    end
  end
end
