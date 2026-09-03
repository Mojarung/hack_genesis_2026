# frozen_string_literal: true

require "fileutils"
require "yaml"

module PayoutRouter
  module Output
    # YAML на диск (политики): UTF-8, LF, без якорей и тегов классов.
    module YAMLWriter
      module_function

      def write(path, document, header: nil)
        FileUtils.mkdir_p(File.dirname(path))
        body = YAML.dump(document).sub(/\A---\n/, "")
        File.open(path, "wb") do |file|
          file.write("#{header}\n\n") if header
          file.write(body)
        end
        path
      end
    end
  end
end
