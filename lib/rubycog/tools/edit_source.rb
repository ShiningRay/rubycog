# frozen_string_literal: true

require 'ruby_llm'
require_relative '../source_path'
require_relative '../source_edit'

module Rubycog
  # Replaces one exact string in a whitelisted file, with a backup and a syntax
  # check. The caller must approve the call; the diff is in the result.
  class EditSourceTool < RubyLLM::Tool
    def self.tool_name = 'edit_source'

    description <<~DESCRIPTION.strip
      Edit one RubyCog source file by replacing an exact string. The path must
      be in the project whitelist. old_string must match exactly once; pass an
      empty old_string to create a new test/ or docs/ file. After writing, the
      tool runs ruby -c on Ruby files and restores the backup if the syntax is
      broken. Run
      run_tests afterwards and tell the user a restart is required.
    DESCRIPTION

    parameter :path, type: :string, description: 'Relative path, for example lib/rubycog/agent.rb'
    parameter :old_string, type: :string, description: 'Exact text to replace; empty only for new test/docs files'
    parameter :new_string, type: :string, description: 'Replacement text'
    parameter :reason, type: :string, description: 'Why this edit is needed'

    requires_approval

    def initialize(self_iteration: nil, root: Rubycog.root)
      super()
      @self_iteration = self_iteration
      @root = root
    end

    def execute(path:, old_string:, new_string:, reason:)
      raise ArgumentError, 'reason is required' if reason.to_s.strip.empty?

      full, relative = SourcePath.resolve(path, root: @root, write: true, must_exist: false)
      result = SourceEdit.apply(
        full, relative, old_string, new_string, reason: reason,
        backup_root: File.join(@root, '.rubycog', 'backups')
      )
      record(relative, reason, result)

      if result[:ok]
        "edited #{relative}\n#{trim(result[:diff])}\n#{result[:syntax]}\n" \
          'Run tests next; the change is not active until /restart.'
      else
        "edit_source failed at #{result[:stage]}: #{result[:error]}\n" \
          "restored: #{result[:backup] ? 'from backup' : 'new file removed'}"
      end
    rescue ArgumentError => e
      "edit_source error: #{e.message}"
    end

    private

    def record(relative, reason, result)
      @self_iteration&.record_edit(
        path: relative, reason: reason, ok: result[:ok],
        diff: result[:diff], backup: result[:backup], error: result[:error]
      )
    end

    def trim(text)
      value = text.to_s
      value.length > 4_000 ? "#{value[0, 4_000]}\n… (truncated)" : value
    end
  end
end
