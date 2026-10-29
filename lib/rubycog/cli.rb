# frozen_string_literal: true

require 'optparse'

module Rubycog
  module CLI
    def self.start(argv, stdout: $stdout, stderr: $stderr)
      options = {}
      parser = OptionParser.new do |opts|
        opts.banner = 'Usage: rubycog [--model MODEL]'
        opts.on('-m', '--model MODEL', 'RubyLLM model ID (or RUBYCOG_MODEL)') do |model|
          options[:model] = model
        end
        opts.on('-h', '--help', 'Show this help') do
          stdout.puts opts
          return 0
        end
        opts.on('-v', '--version', 'Show version') do
          stdout.puts Rubycog::VERSION
          return 0
        end
      end
      parser.parse!(argv)

      Agent.configure
      TUI.new(Agent.new(model: options[:model])).run
      0
    rescue OptionParser::ParseError => e
      stderr.puts "rubycog: #{e.message}"
      stderr.puts parser
      1
    rescue StandardError => e
      stderr.puts "rubycog: #{e.class}: #{e.message}"
      1
    end
  end
end
