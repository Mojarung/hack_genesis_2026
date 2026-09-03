# frozen_string_literal: true

if ENV["COVERAGE"] != "0"
  require "simplecov"
  SimpleCov.start do
    skip "/spec/"
    skip "/vendor/"
    enable_coverage :branch
    minimum_coverage 80
  end
end

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "payout_router"
require "stringio"
require "tmpdir"

Dir[File.expand_path("support/**/*.rb", __dir__)].each { |file| require file }

RSpec.configure do |config|
  config.expect_with(:rspec) { |expectations| expectations.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random
  config.include Builders
  config.include CaptureOutput
end
