# frozen_string_literal: true

require 'ruby_llm'
require_relative '../source_path'
require_relative '../source_edit'

module Rubycog
  # Read-only access to RubyCog's own source, scoped to the project whitelist.
  class ReadSourceTool < RubyLLM::Tool
    def self.tool_name = 'read_source'

    description <<~DESCRIPTION.strip
      Read a RubyCog source file from the project whitelist. Use it before
      editing the agent itself. Paths are relative to the RubyCog project root;
      absolute paths and files outside the whitelist are rejected.
    DESCRIPTION

    parameter :path, type: :string, description: 'Relative path, for example lib/rubycog/agent.rb'
    parameter :start_line, type: :integer, required: false, description: 'First line (1-based)'
    parameter :end_line, type: :integer, required: false, description: 'Last line (inclusive)'

    def initialize(root: Rubycog.root)
      super()
      @root = root
    end

    def execute(path:, start_line: nil, end_line: nil)
      full, relative = SourcePath.resolve(path, root: @root)
      SourceEdit.read(full, relative, start_line: start_line, end_line: end_line)
    rescue ArgumentError => e
      "read_source error: #{e.message}"
    end
  end
end
