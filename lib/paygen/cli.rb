# frozen_string_literal: true

require "thor"

module Paygen
  class CLI < Thor
    def self.exit_on_failure? = true

    desc "generate SPEC", "Сгенерировать интеграцию по OpenAPI-спецификации"
    option :out, aliases: "-o", default: "out", desc: "каталог результата"
    option :name, aliases: "-n", desc: "имя гема/модуля (по умолчанию из info.title)"
    option :base_url, desc: "переопределить базовый URL"
    def generate(spec_path)
      api = analyze(spec_path)
      files = Generator.new(api, out_dir: options[:out], gem_name: options[:name]).call
      say "#{api.title} v#{api.version} → #{options[:out]}", :green
      say "  ресурсов: #{api.resources.size}, операций: #{api.operations.size}, схем: #{api.schemas.size}"
      files.each { |file| say "  + #{file}", :cyan }
    rescue Paygen::Error => e
      say_error "ошибка: #{e.message}", :red
      exit 1
    end

    desc "describe SPEC", "Показать, что генератор увидел в спецификации"
    def describe(spec_path)
      api = analyze(spec_path)
      say "#{api.title} v#{api.version}", :green
      say "base_url: #{api.base_url}"
      say "auth:     #{api.auth.kind}#{" (#{api.auth.name} в #{api.auth.location})" unless api.auth.none?}"
      api.resources.each do |resource|
        say "\n#{resource.class_name} (#{resource.operations.size})", :yellow
        resource.operations.each do |op|
          say format("  %-6s %-40s %s", op.http_method.upcase, op.path, op.method_name)
        end
      end
    rescue Paygen::Error => e
      say_error "ошибка: #{e.message}", :red
      exit 1
    end

    desc "version", "Версия генератора"
    def version = say(Paygen::VERSION)

    private

    def analyze(spec_path)
      Analyzer.call(SpecLoader.load(spec_path), base_url: options[:base_url])
    end
  end
end
