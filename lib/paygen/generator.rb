# frozen_string_literal: true

require "erb"
require "fileutils"

module Paygen
  # Рендерит IR::Api в дерево файлов: клиент, доки, тесты.
  # Добавить новый артефакт = положить .erb в templates/ и добавить строку в #call.
  class Generator
    TEMPLATES = File.join(__dir__, "templates")

    attr_reader :written

    def initialize(api, out_dir:, gem_name: nil)
      @api = api
      @out = File.expand_path(out_dir)
      @gem_name = gem_name && !gem_name.empty? ? IR.rubyize(gem_name) : IR.rubyize(api.title)
      @written = []
    end

    def call
      render "client/entrypoint.rb.erb", "lib/#{@gem_name}.rb"
      render "client/version.rb.erb",    "lib/#{@gem_name}/version.rb"
      render "client/errors.rb.erb",     "lib/#{@gem_name}/errors.rb"
      render "client/client.rb.erb",     "lib/#{@gem_name}/client.rb"
      @api.resources.each do |resource|
        render "client/resource.rb.erb", "lib/#{@gem_name}/resources/#{resource.file_name}.rb", resource: resource
        render "tests/resource_spec.rb.erb", "spec/#{resource.file_name}_spec.rb", resource: resource
      end
      render "tests/spec_helper.rb.erb", "spec/spec_helper.rb"
      render "project/Gemfile.erb",      "Gemfile"
      render "project/rspec.erb",        ".rspec"
      render "docs/README.md.erb",       "README.md"
      @written
    end

    private

    def render(template, target, **locals)
      erb = ERB.new(File.read(File.join(TEMPLATES, template)), trim_mode: "-")
      erb.filename = template
      context = Context.new(api: @api, gem_name: @gem_name, **locals)
      path = File.join(@out, target)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, erb.result(context.exposed_binding))
      @written << target
    end

    # Всё, что доступно внутри шаблонов. Логика форматирования живёт здесь,
    # чтобы .erb оставались читаемыми.
    class Context
      def initialize(**attrs)
        @attrs = attrs
        attrs.each { |key, value| define_singleton_method(key) { value } }
      end

      def exposed_binding = binding

      def module_name = IR.classify(@attrs[:gem_name])

      def paygen_version = Paygen::VERSION

      # Как в примерах кода создаётся клиент — зависит от схемы авторизации.
      def client_init(secret = '"test-key"')
        case @attrs[:api].auth.kind
        when :basic then "#{module_name}::Client.new(username: #{secret}, password: #{secret})"
        when :none then "#{module_name}::Client.new"
        else "#{module_name}::Client.new(api_key: #{secret})"
        end
      end

      # В спеке успешный ответ может быть "2XX" или "default" — в тесте нужен числовой статус.
      def success_code(operation)
        code = operation.success_status.to_s[/\d{3}/]
        code || "200"
      end

      # Сигнатура метода ресурса: path-параметры позиционно, остальное — ключевыми.
      def signature(operation)
        args = operation.path_params.map(&:ruby_name)
        args << "body:" if operation.body&.required?
        args << "body: nil" if operation.body && !operation.body.required?
        operation.query_params.sort_by { |p| p.required? ? 0 : 1 }.each do |param|
          args << (param.required? ? "#{param.ruby_name}:" : "#{param.ruby_name}: nil")
        end
        args << "headers: {}"
        args.join(", ")
      end

      # Хеш query-параметров с исходными (не рубифицированными) именами.
      def query_literal(operation)
        return "{}" if operation.query_params.empty?

        pairs = operation.query_params.map { |p| "\"#{p.name}\" => #{p.ruby_name}" }
        "{ #{pairs.join(", ")} }.compact"
      end

      def doc_comment(text, indent: 6)
        return [] if text.nil? || text.strip.empty?

        text.strip.split("\n").map { |line| "#{" " * indent}# #{line.strip}" }
      end

      # Пример значения для тестов/доков.
      def sample_value(param)
        return param.example.inspect unless param.example.nil?
        return param.enum.first.inspect if param.enum && !param.enum.empty?

        case param.type
        when "integer" then "1"
        when "number" then "1.0"
        when "boolean" then "true"
        when "array" then "[]"
        when "object" then "{}"
        else "\"#{param.ruby_name}-example\""
        end
      end

      def sample_args(operation)
        args = operation.path_params.map { |p| sample_value(p) }
        args << "body: #{sample_body(operation)}" if operation.body&.required?
        operation.query_params.select(&:required?).each { |p| args << "#{p.ruby_name}: #{sample_value(p)}" }
        args.join(", ")
      end

      def sample_body(operation)
        props = operation.body&.properties.to_a.select(&:required?)
        return "{}" if props.empty?

        "{ #{props.map { |p| "\"#{p.name}\" => #{sample_value(p)}" }.join(", ")} }"
      end

      # Путь с подставленными примерами — для stub_request в тестах.
      def sample_path(operation)
        operation.path.gsub(/\{([^}]+)\}/) do
          param = operation.path_params.find { |p| p.name == Regexp.last_match(1) }
          param ? sample_value(param).delete('"') : Regexp.last_match(1)
        end
      end
    end
  end
end
