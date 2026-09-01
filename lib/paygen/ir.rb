# frozen_string_literal: true

module Paygen
  # Промежуточное представление: всё, что шаблонам нужно знать о провайдере.
  # Шаблоны НЕ должны лезть в сырой OpenAPI-hash — только сюда.
  module IR
    def self.rubyize(name)
      Paygen.inflector.underscore(name.to_s.gsub(/[^A-Za-z0-9]+/, "_")).squeeze("_").gsub(/\A_|_\z/, "")
    end

    def self.classify(name)
      Paygen.inflector.camelize(rubyize(name))
    end

    Api = Struct.new(:title, :version, :description, :base_url, :auth, :resources, :schemas, keyword_init: true) do
      def operations = resources.flat_map(&:operations)
    end

    # Группа операций (обычно один tag из OpenAPI) → один класс-ресурс в клиенте.
    Resource = Struct.new(:name, :description, :operations, keyword_init: true) do
      def class_name = IR.classify(name)
      def file_name  = IR.rubyize(name)
      def method_name = IR.rubyize(name)
    end

    Operation = Struct.new(:id, :http_method, :path, :summary, :description,
                           :path_params, :query_params, :header_params,
                           :body, :success_status, :responses, :idempotent,
                           keyword_init: true) do
      def method_name = IR.rubyize(id)

      def body? = !body.nil?

      # Позиционные аргументы метода: параметры пути всегда обязательны.
      def positional_args = path_params.map(&:ruby_name)

      def path_template = path.gsub(/\{([^}]+)\}/) { "\#{#{IR.rubyize(Regexp.last_match(1))}}" }
    end

    Param = Struct.new(:name, :location, :required, :type, :format, :description, :enum, :example,
                       keyword_init: true) do
      def ruby_name = IR.rubyize(name)
      def required? = !!required
    end

    Body = Struct.new(:content_type, :schema_name, :required, :properties, keyword_init: true) do
      def required? = !!required
    end

    # kind: :bearer | :api_key | :basic | :oauth2 | :none
    Auth = Struct.new(:kind, :name, :location, :scheme, :description, keyword_init: true) do
      def none? = kind == :none
    end

    Schema = Struct.new(:name, :type, :description, :properties, :required, keyword_init: true) do
      def class_name = IR.classify(name)
    end

    Property = Struct.new(:name, :type, :format, :description, :required, :enum, :example,
                          keyword_init: true) do
      def ruby_name = IR.rubyize(name)
      def required? = !!required
    end
  end
end
