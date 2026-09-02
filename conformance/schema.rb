# frozen_string_literal: true

module RiverConformance
  # Only the schema vocabulary used by adapter request parameters is needed.
  # Read the actual contract so unknown nested options cannot be silently lost.
  class Schema
    def initialize(contract)
      @contract = contract
      @methods = contract.fetch("methods").to_h { |method| [method.fetch("name"), method.fetch("params")] }
    end

    def check(method, params)
      validate(@methods.fetch(method), params, "params")
    end

    def validate(schema, value, path)
      if schema.key?("$ref")
        schema = schema.fetch("$ref").delete_prefix("#/").split("/").reduce(@contract) { |node, key| node.fetch(key) }
      end
      if schema.key?("type")
        valid = Array(schema.fetch("type")).any? do |type|
          case type
          when "object" then value.is_a?(Hash)
          when "array" then value.is_a?(Array)
          when "string" then value.is_a?(String)
          when "integer" then value.is_a?(Integer)
          when "boolean" then value == true || value == false
          when "null" then value.nil?
          else raise "unsupported schema type #{type}"
          end
        end
        reject(path) unless valid
      end
      reject(path) if schema.key?("enum") && !schema.fetch("enum").include?(value)
      reject(path) if schema.key?("minimum") && value < schema.fetch("minimum")
      reject(path) if schema.key?("minLength") && value.length < schema.fetch("minLength")
      if value.is_a?(Hash)
        properties = schema.fetch("properties", {})
        reject(path) unless (schema.fetch("required", []) - value.keys).empty?
        reject(path) if schema["additionalProperties"] == false && !(value.keys - properties.keys).empty?
        value.each { |key, item| validate(properties.fetch(key), item, "#{path}.#{key}") if properties.key?(key) }
      elsif value.is_a?(Array) && schema.key?("items")
        value.each_with_index { |item, index| validate(schema.fetch("items"), item, "#{path}[#{index}]") }
      end
    end

    def reject(path)
      raise ProtocolError.new(-32602, "invalid #{path}")
    end
  end
end
