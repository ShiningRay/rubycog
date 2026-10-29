# frozen_string_literal: true

module Rubycog
  # Human-readable preview for a tool call. Shared by the agent event stream
  # and the TUI approval prompt.
  module ToolPreview
    module_function

    def for(call)
      arguments = call.arguments.transform_keys(&:to_s)
      case call.name.to_s
      when 'eval'
        arguments['code'].to_s
      when 'read_source'
        "read #{arguments['path']}"
      when 'edit_source'
        "edit #{arguments['path']}\n#{arguments['reason']}"
      when 'run_tests'
        paths = Array(arguments['paths']).reject(&:empty?)
        paths.empty? ? 'run all tests' : "run tests: #{paths.join(', ')}"
      when 'search_docs'
        "search docs: #{arguments['query']}"
      when 'get_doc'
        target = [arguments['class_name'], arguments['method']].compact.join('#')
        "read doc: #{target}"
      when 'get_source'
        target = [arguments['class_name'], arguments['method']].compact.join('#')
        "read source: #{target}"
      else
        arguments.inspect
      end
    end
  end
end
