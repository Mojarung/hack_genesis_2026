# frozen_string_literal: true

# Перехват stdout/stderr для проверки CLI.
module CaptureOutput
  Captured = Data.define(:stdout, :stderr, :status)

  def run_cli(*args)
    out = StringIO.new
    err = StringIO.new
    original_out = $stdout
    original_err = $stderr
    $stdout = out
    $stderr = err
    status = 0
    begin
      PayoutRouter::CLI.start(args)
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout = original_out
      $stderr = original_err
    end
    Captured.new(stdout: out.string, stderr: err.string, status: status)
  end
end
