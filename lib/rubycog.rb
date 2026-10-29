# frozen_string_literal: true

module Rubycog
  def self.root
    File.expand_path('..', __dir__)
  end
end

require_relative 'rubycog/version'
require_relative 'rubycog/eval_tool'
require_relative 'rubycog/source_path'
require_relative 'rubycog/source_edit'
require_relative 'rubycog/self_iteration'
require_relative 'rubycog/tool_preview'
require_relative 'rubycog/tools/read_source'
require_relative 'rubycog/tools/edit_source'
require_relative 'rubycog/tools/run_tests'
require_relative 'rubycog/session'
require_relative 'rubycog/agent'
require_relative 'rubycog/text'
require_relative 'rubycog/tui'
require_relative 'rubycog/cli'
