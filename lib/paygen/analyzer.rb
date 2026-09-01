# frozen_string_literal: true

module Paygen
  # Превращает развёрнутый OpenAPI-hash в IR::Api.
  # Здесь живёт вся «адаптация под разных провайдеров»: как достать auth,
  # как сгруппировать операции, что считать успешным ответом.
  class Analyzer
    HTTP_METHODS = %w[get post put patch delete head options].freeze
    IDEMPOTENT_METHODS = %w[get put delete head options].freeze
    JSON_CT = %r{^application/(\w+\+)?json}

    def self.call(doc, base_url: nil) = new(doc, base_url: base_url).call

    def initialize(doc, base_url: nil)
      @doc = doc
      @base_url = base_url
    end

    def call
      IR::Api.new(
        title: info["title"] || "Payment Provider",
        version: info["version"] || "1.0.0",
        description: info["description"],
        base_url: @base_url || server_url,
        auth: auth,
        resources: resources,
        schemas: schemas
      )
    end

    private

    def info = @doc["info"] || {}

    def server_url
      url = Array(@doc["servers"]).first&.dig("url") || "https://api.example.com"
      vars = Array(@doc["servers"]).first&.dig("variables") || {}
      vars.each { |name, v| url = url.gsub("{#{name}}", (v["default"] || "").to_s) }
      url.sub(%r{/+\z}, "")
    end

    # Берём первую схему безопасности — для хакатонного клиента этого достаточно,
    # остальные перечислим в доке.
    def auth
      schemes = @doc.dig("components", "securitySchemes") || {}
      name, s = schemes.first
      return IR::Auth.new(kind: :none, description: nil) if s.nil?

      kind =
        case [s["type"], s["scheme"]&.downcase]
        in ["http", "basic"] then :basic
        in ["apiKey", _] then :api_key
        in ["oauth2", _] | ["openIdConnect", _] then :oauth2
        else :bearer # http/bearer и всё незнакомое: самый частый случай у платёжных API
        end

      IR::Auth.new(kind: kind, name: s["name"] || name, location: (s["in"] || "header").to_sym,
                   scheme: s["scheme"], description: s["description"])
    end

    def resources
      operations.group_by { |op| op[:tag] }.map do |tag, ops|
        IR::Resource.new(name: tag, description: tag_description(tag), operations: ops.map { |o| o[:op] })
      end
    end

    def tag_description(tag)
      Array(@doc["tags"]).find { |t| t["name"] == tag }&.dig("description")
    end

    def operations
      (@doc["paths"] || {}).flat_map do |path, item|
        next [] unless item.is_a?(Hash)

        shared = Array(item["parameters"])
        item.filter_map do |verb, op|
          next unless HTTP_METHODS.include?(verb) && op.is_a?(Hash)

          { tag: Array(op["tags"]).first || "default", op: build_operation(path, verb, op, shared) }
        end
      end
    end

    def build_operation(path, verb, op, shared)
      params = (shared + Array(op["parameters"])).map { |p| build_param(p) }.compact
      IR::Operation.new(
        id: op["operationId"] || "#{verb}_#{path}",
        http_method: verb,
        path: path,
        summary: op["summary"],
        description: op["description"],
        path_params: params.select { |p| p.location == "path" },
        query_params: params.select { |p| p.location == "query" },
        header_params: params.select { |p| p.location == "header" },
        body: build_body(op["requestBody"]),
        success_status: success_status(op["responses"]),
        responses: (op["responses"] || {}).transform_values { |r| r["description"] },
        idempotent: IDEMPOTENT_METHODS.include?(verb)
      )
    end

    def build_param(param)
      return nil unless param.is_a?(Hash) && param["name"]

      schema = param["schema"] || {}
      IR::Param.new(
        name: param["name"], location: param["in"] || "query", required: param["required"] || param["in"] == "path",
        type: schema["type"] || "string", format: schema["format"], description: param["description"],
        enum: schema["enum"], example: param["example"] || schema["example"] || schema["default"]
      )
    end

    def build_body(request_body)
      return nil unless request_body.is_a?(Hash)

      content = request_body["content"] || {}
      ct, media = content.find { |k, _| k =~ JSON_CT } || content.first
      return nil if media.nil?

      schema = media["schema"] || {}
      IR::Body.new(content_type: ct, schema_name: schema["x-ref-name"], required: request_body["required"],
                   properties: properties(schema))
    end

    def success_status(responses)
      (responses || {}).keys.find { |k| k.to_s.start_with?("2") } || "200"
    end

    def schemas
      (@doc.dig("components", "schemas") || {}).map do |name, schema|
        IR::Schema.new(name: name, type: schema["type"] || "object", description: schema["description"],
                       properties: properties(schema), required: Array(schema["required"]))
      end
    end

    def properties(schema)
      required = Array(schema["required"])
      (schema["properties"] || {}).map do |name, prop|
        prop = {} unless prop.is_a?(Hash)
        IR::Property.new(name: name, type: prop["type"] || "string", format: prop["format"],
                         description: prop["description"], required: required.include?(name),
                         enum: prop["enum"], example: prop["example"] || prop["default"])
      end
    end
  end
end
