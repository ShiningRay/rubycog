# frozen_string_literal: true

require 'optparse'

module Rubycog
  module CLI
    def self.start(argv, stdout: $stdout, stderr: $stderr)
      original_argv = argv.dup
      options = { yolo: false }
      parser = OptionParser.new do |opts|
        opts.banner = 'Usage: rubycog [--model MODEL] [--yolo]'
        opts.on('-m', '--model MODEL', 'RubyLLM model ID (or RUBYCOG_MODEL)') do |model|
          options[:model] = model
        end
        opts.on('-y', '--yolo', 'Run tools without asking for approval (dangerous)') do
          options[:yolo] = true
        end
        opts.on('-s', '--session PATH', 'Conversation file (or RUBYCOG_SESSION)') do |path|
          options[:session] = path
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
      session = Session.new(options[:session] || Session.default_path)
      iteration = SelfIteration.new
      agent = Agent.new(model: options[:model], session: session, self_iteration: iteration)
      TUI.new(agent, yolo: options[:yolo], history: session.messages, session: session,
                     self_iteration: iteration, argv: original_argv).run
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
