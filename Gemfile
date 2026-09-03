# frozen_string_literal: true

source "https://rubygems.org"

ruby "~> 4.0"

gem "csv", "~> 3.3"       # с Ruby 3.4 — bundled gem, без явной строки не загрузится
gem "thor", "~> 1.5"      # CLI
gem "zeitwerk", "~> 2.8"  # автозагрузка lib/ по соглашению об именах

group :development, :test do
  gem "rake", "~> 13.4"
  gem "rspec", "~> 3.13"
  gem "rubocop", "~> 1.90", require: false
  gem "rubocop-rspec", "~> 3.10", require: false
  gem "simplecov", "~> 1.1", require: false
end
