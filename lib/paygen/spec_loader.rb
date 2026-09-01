# frozen_string_literal: true

require "yaml"
require "json"

module Paygen
  # Читает OpenAPI (YAML/JSON) и разворачивает локальные $ref.
  # Внешние ($ref на другой файл/URL) намеренно оставляем как есть — чтобы не тянуть сеть.
  class SpecLoader
    def self.load(path) = new(path).load

    def initialize(path)
      @path = path.to_s
    end

    def load
      raise SpecError, "файл спецификации не найден: #{@path}" unless File.file?(@path)

      @doc = parse(File.read(@path))
      raise SpecError, "не похоже на OpenAPI: нет ключа openapi/swagger" unless @doc.is_a?(Hash) &&
                                                                                (@doc["openapi"] || @doc["swagger"])

      resolve(@doc, [])
    end

    private

    def parse(raw)
      if @path.end_with?(".json")
        JSON.parse(raw)
      else
        YAML.safe_load(raw, aliases: true, permitted_classes: [Date, Time])
      end
    rescue Psych::SyntaxError, JSON::ParserError => e
      raise SpecError, "не удалось разобрать #{@path}: #{e.message}"
    end

    def resolve(node, seen)
      case node
      when Hash then resolve_hash(node, seen)
      when Array then node.map { |v| resolve(v, seen) }
      else node
      end
    end

    def resolve_hash(node, seen)
      ref = node["$ref"]
      return node.transform_values { |v| resolve(v, seen) } unless ref.is_a?(String) && ref.start_with?("#/")
      # циклическая ссылка (Payment → Refund → Payment) — обрываем, оставляя маркер
      return { "type" => "object", "x-ref-name" => ref.split("/").last, "x-cycle" => true } if seen.include?(ref)

      target = resolve(dig_ref(ref), seen + [ref])
      siblings = resolve(node.except("$ref"), seen)
      target.is_a?(Hash) ? target.merge(siblings).merge("x-ref-name" => ref.split("/").last) : target
    end

    def dig_ref(ref)
      keys = ref.delete_prefix("#/").split("/").map { |k| k.gsub("~1", "/").gsub("~0", "~") }
      value = @doc.dig(*keys)
      raise SpecError, "не разрешается $ref: #{ref}" if value.nil?

      value
    end
  end
end
