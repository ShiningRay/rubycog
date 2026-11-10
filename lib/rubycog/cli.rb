# frozen_string_literal: true

require 'optparse'

module Rubycog
  # Loads KEY=value pairs from .env files into ENV before configuration runs.
  #
  # Variables already present in the real environment always win, because
  # Dotenv.load only fills keys that are unset. Candidates are read in order, so
  # the shell's working directory beats RubyCog's own directory when both define
  # the same key. Missing files are ignored and a malformed line is skipped.
  module EnvFile
    FILENAME = '.env'

    # Candidate files in priority order: the working directory first, then the
    # RubyCog checkout itself (the same file when the agent runs from its root).
    def self.paths(dir: Dir.pwd, root: Rubycog.root)
      [File.join(dir, FILENAME), File.join(root, FILENAME)].uniq
    end

    # Reads every existing candidate and returns the paths that were read.
    #
    # Passing paths directly keeps tests independent of the working directory.
    # Without the dotenv gem nothing is loaded and a warning explains why, so a
    # missing bundle cannot silently drop the API keys.
    def self.load(paths = self.paths)
      existing = paths.select { |path| File.file?(path) }
      return [] if existing.empty?
      return missing_gem unless available?

      existing.each { |path| Dotenv.load(path) }
      existing
    end

    # True when the dotenv gem can be required; memoized because startup and the
    # error path both ask.
    def self.available?
      return @available unless @available.nil?

      require 'dotenv'
      @available = true
    rescue LoadError
      @available = false
    end

    def self.missing_gem
      warn 'rubycog: dotenv is not installed; ignoring .env (run bundle install)'
      []
    end
  end

  module CLI
    def self.start(argv, stdout: $stdout, stderr: $stderr)
      original_argv = argv.dup
      options = { yolo: false }
      parser = OptionParser.new do |opts|
        opts.banner = 'Usage: rubycog [--model MODEL] [--session PATH] [--name NAME] [--yolo] ' \
                      '[--isolated-eval] [--headless --task TEXT | --daemon]'
        opts.on('-m', '--model MODEL', 'RubyLLM model ID (or RUBYCOG_MODEL)') do |model|
          options[:model] = model
        end
        opts.on('-y', '--yolo', 'Run tools without asking for approval (dangerous)') do
          options[:yolo] = true
        end
        opts.on('-s', '--session PATH', 'Conversation file (or RUBYCOG_SESSION)') do |path|
          options[:session] = path
        end
        opts.on('-n', '--name NAME', 'Name shown in the UI (or RUBYCOG_NAME)') do |name|
          options[:name] = name
        end
        opts.on('--isolated-eval', 'Drop eval local variables after every call') do
          options[:isolated_eval] = true
        end
        opts.on('--headless', 'Run without the curses UI (needs --task or --daemon)') do
          options[:headless] = true
        end
        opts.on('--task TEXT', 'Answer one prompt without the TUI, then exit') do |text|
          options[:task] = text
        end
        opts.on('--daemon', 'Keep polling the inbox directory for task files') do
          options[:daemon] = true
        end
        opts.on('--inbox DIR', "Task inbox (default #{Headless::DEFAULT_INBOX})") do |dir|
          options[:inbox] = dir
        end
        opts.on('--heartbeat PATH', "Heartbeat file (default #{Headless::DEFAULT_HEARTBEAT})") do |path|
          options[:heartbeat] = path
        end
        opts.on('--interval SECONDS', Float, "Inbox poll interval (default #{Headless::DEFAULT_INTERVAL})") do |seconds|
          options[:interval] = seconds
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

      headless_requested = options[:headless] || options[:task] || options[:daemon]
      if headless_requested && !options[:task] && !options[:daemon]
        stderr.puts 'rubycog: --headless needs --task TEXT or --daemon'
        return 1
      end
      if options[:interval] && !options[:interval].positive?
        stderr.puts 'rubycog: --interval must be greater than 0'
        return 1
      end

      EnvFile.load
      Rubycog.name = options[:name] || ENV[Rubycog::NAME_ENV]
      Agent.configure
      session = Session.new(options[:session] || Session.default_path)
      iteration = SelfIteration.new
      agent = Agent.new(model: options[:model], session: session, self_iteration: iteration,
                        isolated_eval: options[:isolated_eval])
      if headless_requested
        runner = Headless.new(agent, stdout: stdout, stderr: stderr,
                                     inbox: options[:inbox] || Headless::DEFAULT_INBOX,
                                     heartbeat: options[:heartbeat] || Headless::DEFAULT_HEARTBEAT,
                                     interval: options[:interval] || Headless::DEFAULT_INTERVAL)
        return runner.run(task: options[:task], daemon: options[:daemon] || false)
      end

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
