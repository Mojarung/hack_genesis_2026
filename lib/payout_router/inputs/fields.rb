# frozen_string_literal: true

module PayoutRouter
  module Inputs
    # Разбор полей входных файлов. Любая проблема — InputError с точным адресом
    # (файл, объект, поле), чтобы причину было видно без стектрейса.
    module Fields
      module_function

      def string!(hash, key, where:)
        value = string(hash, key, where:)
        raise InputError, "#{where}: поле #{key} обязательно и должно быть непустой строкой" if value.nil?

        value
      end

      # Идентификатор: непустая строка; целое число тоже принимаем (103 → "103") — так тоже выгружают.
      def identifier!(hash, key, where:)
        value = hash[key]
        return value.to_s if value.is_a?(Integer)

        string!(hash, key, where:)
      end

      def string(hash, key, where:)
        value = hash[key]
        return nil if value.nil?
        unless value.is_a?(String)
          raise InputError,
                "#{where}: поле #{key} должно быть строкой, получено #{value.inspect}"
        end

        stripped = value.strip
        stripped.empty? ? nil : stripped
      end

      # Число или nil (nil = «не задано»). min/max — допустимый диапазон.
      def number(hash, key, where:, min: nil, max: nil)
        value = hash[key]
        return nil if value.nil?
        unless value.is_a?(Numeric)
          raise InputError,
                "#{where}: поле #{key} должно быть числом, получено #{value.inspect}"
        end
        raise InputError, "#{where}: поле #{key} = #{value} меньше допустимого #{min}" if min && value < min
        raise InputError, "#{where}: поле #{key} = #{value} больше допустимого #{max}" if max && value > max

        value
      end

      # Сумма заявки: обязательна, положительна; целые значения приводим к Integer.
      # Число в строке ("15000") принимаем — так иногда выгружают из биллинга.
      def amount!(hash, key, where:)
        value = number(numeric_string_coerced(hash, key), key, where:)
        raise InputError, "#{where}: поле #{key} обязательно" if value.nil?
        raise InputError, "#{where}: сумма должна быть положительной, получено #{value}" unless value.positive?

        value == value.floor ? value.to_i : value
      end

      def numeric_string_coerced(hash, key)
        value = hash[key]
        return hash unless value.is_a?(String) && value.strip.match?(/\A-?\d+(\.\d+)?\z/)

        hash.merge(key => Float(value.strip))
      end

      def boolean(hash, key, where:, default: false)
        value = hash[key]
        return default if value.nil?
        return value if [true, false].include?(value)

        raise InputError, "#{where}: поле #{key} должно быть true/false, получено #{value.inspect}"
      end

      # Список кодов (банков): нормализуем к нижнему регистру, пустые строки выбрасываем.
      def string_list(hash, key, where:)
        value = hash[key]
        return [] if value.nil?
        unless value.is_a?(Array) && value.all?(String)
          raise InputError, "#{where}: поле #{key} должно быть списком строк, получено #{value.inspect}"
        end

        value.map { |item| item.strip.downcase }.reject(&:empty?)
      end

      # Время: ISO 8601; «2026-07-30 09:00:00» без T тоже разбираем, остальное — ошибка с адресом.
      def time(hash, key, where:)
        value = hash[key]
        return nil if value.nil?

        Time.iso8601(value.to_s)
      rescue ArgumentError
        parse_time_loosely(value, key, where)
      end

      def parse_time_loosely(value, key, where)
        raise ArgumentError unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}/)

        Time.parse(value)
      rescue ArgumentError
        raise InputError, "#{where}: поле #{key} должно быть датой ISO 8601, получено #{value.inspect}"
      end
    end
  end
end
