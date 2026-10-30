# frozen_string_literal: true

module Rubycog
  # Name the UI shows when nothing overrides it.
  DEFAULT_NAME = 'RubyCog'
  # Environment variable that overrides the display name.
  NAME_ENV = 'RUBYCOG_NAME'

  def self.root
    File.expand_path('..', __dir__)
  end

  # Display name for the header and the assistant transcript label.
  #
  # Defaults to DEFAULT_NAME. `--name` and NAME_ENV change it, so a fork, or a
  # second persona on the same machine, does not have to edit code to be called
  # something else. The agent's instructions and tool descriptions still say
  # RubyCog: they name the project, not the speaker.
  def self.name
    @name || DEFAULT_NAME
  end

  # Sets the display name; nil or blank restores DEFAULT_NAME.
  #
  # Control characters are dropped because the name is written straight into a
  # curses line, where a newline or tab would corrupt the header.
  def self.name=(value)
    text = value.to_s.gsub(/[[:cntrl:]]/, '').strip
    @name = text.empty? ? nil : text
  end
end

require_relative 'rubycog/version'
require_relative 'rubycog/eval_tool'
require_relative 'rubycog/source_path'
require_relative 'rubycog/source_edit'
require_relative 'rubycog/source_docs'
require_relative 'rubycog/self_iteration'
require_relative 'rubycog/experience'
require_relative 'rubycog/web_fetcher'
require_relative 'rubycog/proposal'
require_relative 'rubycog/worktree'
require_relative 'rubycog/evolution'
require_relative 'rubycog/benchmark_runner'
require_relative 'rubycog/static_analysis'
require_relative 'rubycog/heuristic_scan'
require_relative 'rubycog/introspection'
require_relative 'rubycog/idle_watcher'
require_relative 'rubycog/tool_preview'
require_relative 'rubycog/tools/read_source'
require_relative 'rubycog/tools/edit_source'
require_relative 'rubycog/tools/run_tests'
require_relative 'rubycog/tools/search_docs'
require_relative 'rubycog/tools/get_doc'
require_relative 'rubycog/tools/get_source'
require_relative 'rubycog/tools/learn_from_url'
require_relative 'rubycog/tools/save_experience'
require_relative 'rubycog/tools/search_experiences'
require_relative 'rubycog/tools/propose_evolution'
require_relative 'rubycog/tools/list_proposals'
require_relative 'rubycog/tools/approve_proposal'
require_relative 'rubycog/tools/run_evolution'
require_relative 'rubycog/tools/evolution_edit'
require_relative 'rubycog/tools/evolution_run_tests'
require_relative 'rubycog/tools/finish_evolution'
require_relative 'rubycog/tools/rollback_evolution'
require_relative 'rubycog/tools/suggest_proposals'
require_relative 'rubycog/tools/evolution_benchmark'
require_relative 'rubycog/tools/introspect_code'
require_relative 'rubycog/session'
require_relative 'rubycog/agent'
require_relative 'rubycog/text'
require_relative 'rubycog/tui'
require_relative 'rubycog/cli'
