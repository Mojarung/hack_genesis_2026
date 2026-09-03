# frozen_string_literal: true

require "rspec/core/rake_task"
require "rubocop/rake_task"

RSpec::Core::RakeTask.new(:spec)
RuboCop::RakeTask.new(:lint)

CLI = "ruby -Ilib bin/payout_router"

desc "Роутинг публичной очереди (10 заявок) → out/routing_decisions.json + отчёт"
task :route do
  sh "#{CLI} route --queue data/operations_queue_10.json --out out"
end

desc "Проверить out/routing_decisions.json скриптом организаторов"
task validate: :route do
  sh "ruby scripts/validate_10.rb out/routing_decisions.json"
end

desc "Итоговые файлы для жюри: routing_decisions_test.json и routing_report_test.json в корне"
task :submit do
  sh "#{CLI} route --queue data/operations_queue_test.json --out . --suffix _test"
end

desc "Бенчмарк: синтетическая очередь на N заявок (N=BENCH_N, по умолчанию 50000)"
task :bench do
  sh "#{CLI} bench --operations #{ENV.fetch("BENCH_N", 50_000)}"
end

task default: %i[spec lint]
