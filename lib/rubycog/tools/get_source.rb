# frozen_string_literal: true

require 'ruby_llm'
require_relative '../source_docs'

module Rubycog
  # Reads the Ruby source of a class method or instance method, starting from
  # its definition and ending at the matching end.
  class GetSourceTool < RubyLLM::Tool
    def self.tool_name = 'get_source'

    description <<~DESCRIPTION.strip
      Read the Ruby source of a class method or instance method in RubyCog or
      the current project. Use it when a class has no documentation comment or
      when the comment does not explain the behavior.
    DESCRIPTION

    parameter :class_name, type: :string, description: 'Class or module name'
    parameter :method, type: :string, description: 'Method name'
    parameter :kind, type: :string, required: false, description: 'instance (default) or class'

    def initialize(roots: nil)
      super()
      @roots = roots
    end

    def execute(class_name:, method:, kind: 'instance')
      kind = kind.to_s.empty? ? 'instance' : kind.to_s
      raise ArgumentError, 'kind must be instance or class' unless %w[instance class].include?(kind)

      entry = SourceDocs.find(
        class_name: class_name, method: method, kind: kind, roots: @roots || SourceDocs.roots
      )
      source = entry ? SourceDocs.source_for(entry) : SourceDocs.runtime_source(
        class_name: class_name, method: method, kind: kind
      )
      return "no Ruby source for #{class_name}#{kind == 'class' ? '.' : '#'}#{method}" if source.to_s.empty?

      source
    rescue ArgumentError => e
      "get_source error: #{e.message}"
    end
  end
end
