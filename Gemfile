# frozen_string_literal: true

source "https://rubygems.org"

ruby "~> 3.4"

gem "dry-inflector", "~> 1.1"   # camelize/underscore для генерации имён
gem "thor", "~> 1.3"            # CLI

# рантайм сгенерированного клиента (нужен, чтобы гонять сгенерированные тесты)
gem "faraday", "~> 2.9"
gem "faraday-retry", "~> 2.2"

group :development, :test do
  gem "rake", "~> 13.2"
  gem "rspec", "~> 3.13"
  gem "rubocop", "~> 1.65", require: false
  gem "webmock", "~> 3.23"
end
