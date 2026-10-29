# frozen_string_literal: true

require 'ruby_llm'
require_relative '../source_docs'

module Rubycog
  # Reads the documentation comment for a class or method.
  class GetDocTool < RubyLLM::Tool
    def self.tool_name = 'get_doc'

    description <<~DESCRIPTION.strip
      Read the documentation comment for a class, module or method. Project
      source comments are preferred; when none exists, fall back to ri. Use
      get_source when a class has no comment.
    DESCRIPTION

    parameter :class_name, type: :string, description: 'Class or module name, e.g. Rubycog::Agent'
    parameter :method, type: :string, required: false, description: 'Method name; omit to read the class comment'
    parameter :kind, type: :string, required: false, description: 'instance (default) or class'

    def initialize(roots: nil)
      super()
      @roots = roots
    end

    def execute(class_name:, method: nil, kind: 'instance')
      kind = kind.to_s.empty? ? 'instance' : kind.to_s
      raise ArgumentError, 'kind must be instance or class' unless %w[instance class].include?(kind)

      text = SourceDocs.doc_for(
        class_name: class_name, method: method, kind: kind, roots: @roots || SourceDocs.roots
      )
      return "no documentation for #{target(class_name, method, kind)}; use get_source" if text.to_s.empty?

      text
    rescue ArgumentError => e
      "get_doc error: #{e.message}"
    end

    private

    def target(class_name, method, kind)
      return class_name.to_s if method.to_s.empty?

      "#{class_name}#{kind == 'class' ? '.' : '#'}#{method}"
    end
  end
end
