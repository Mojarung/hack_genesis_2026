# frozen_string_literal: true

require "fileutils"

module PayoutRouter
  module Output
    # JSON на диск: UTF-8, LF, читаемые отступы (файлы смотрят люди — жюри и эксперты).
    module JSONWriter
      module_function

      def write(path, data)
        FileUtils.mkdir_p(File.dirname(path))
        File.open(path, "wb") { |file| file.write(JSON.pretty_generate(data), "\n") }
        path
      end
    end
  end
end
