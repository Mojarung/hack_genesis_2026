# frozen_string_literal: true

# Симулятор с заранее заданной последовательностью исходов — для проверки каскада попыток.
class ScriptedSimulator
  def initialize(*results)
    @results = results
  end

  def mode = "scripted"

  def call(_candidate, _operation)
    result = @results.shift || "approved"
    PayoutRouter::Simulation::Outcome.new(result: result, latency_sec: 30)
  end
end
