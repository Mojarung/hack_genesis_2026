# frozen_string_literal: true

module PayoutRouter
  module Inputs
    module JSONFile
      module_function

      def read(path)
        raise InputError, "файл не найден: #{path}" unless File.file?(path.to_s)

        JSON.parse(File.read(path, mode: "r:bom|utf-8"))
      rescue JSON::ParserError => e
        raise InputError, "#{path}: невалидный JSON — #{e.message.lines.first&.strip}"
      end
    end
  end
end
