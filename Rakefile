# frozen_string_literal: true

require "rspec/core/rake_task"
require "rubocop/rake_task"

RSpec::Core::RakeTask.new(:spec)
RuboCop::RakeTask.new(:lint)

desc "Прогнать генератор на демо-спеке в out/"
task :demo do
  sh "ruby -Ilib bin/paygen generate fixtures/provider_api.yaml --out out/demo"
end

task default: %i[spec lint]
