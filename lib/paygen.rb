# frozen_string_literal: true

require "dry/inflector"

# Paygen — генератор интеграций с платёжными провайдерами по OpenAPI-спецификации.
#
# Пайплайн: SpecLoader (файл → hash с развёрнутыми $ref)
#        →  Analyzer   (hash → IR::Api)
#        →  Generator  (IR::Api + ERB-шаблоны → файлы на диске)
module Paygen
  class Error < StandardError; end
  class SpecError < Error; end

  def self.inflector
    @inflector ||= Dry::Inflector.new
  end
end

require_relative "paygen/version"
require_relative "paygen/ir"
require_relative "paygen/spec_loader"
require_relative "paygen/analyzer"
require_relative "paygen/generator"
require_relative "paygen/cli"
