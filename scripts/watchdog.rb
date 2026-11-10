#!/usr/bin/env ruby
# frozen_string_literal: true

# Crash watchdog for RubyCog.
#
# Runs a command, restarts it when it crashes, and leaves a crash bundle
# (meta.json + README.md + the tail of the run log) for an AI repair agent.
# With --repair it also runs a repair command, with the report path substituted
# for %{report}, before restarting.
#
# This file is intentionally stdlib-only and does not load bundler: it must be
# able to supervise a process whose bundle is broken, which is exactly when the
# repair loop matters.
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'rbconfig'
require 'time'

module RubyCogWatchdog
  # Where status, run logs and crash bundles live.
  class Paths
    attr_reader :log_dir, :crash_root, :status_path

    def initialize(log_dir)
      @log_dir = File.expand_path(log_dir)
      @crash_root = File.join(@log_dir, 'crashes')
      @status_path = File.join(@log_dir, 'status.json')
    end
  end

  # Command line options with the documented defaults.
  class Options
    attr_accessor :log_dir, :repair, :repair_timeout, :max_restarts, :backoff,
                  :stable_seconds, :no_restart, :once, :stop_file, :command, :help

    def initialize
      @log_dir = '.rubycog/watchdog'
      @repair = nil
      @repair_timeout = 900.0
      @max_restarts = 5
      @backoff = 5.0
      @stable_seconds = 120.0
      @no_restart = false
      @once = false
      @stop_file = nil
      @command = []
      @help = false
    end
  end

  # Parses argv and hands off to the supervisor. Returns a process exit code so
  # the script stays a thin, testable wrapper.
  class CLI
    def self.start(argv)
      options = Options.new
      parser = build_parser(options)
      begin
        rest = parser.parse(argv)
      rescue OptionParser::ParseError => e
        warn "watchdog: #{e.message}"
        warn parser.banner
        return 1
      end

      if options.help
        puts parser
        return 0
      end

      options.command = rest
      problem = validate(options)
      if problem
        warn "watchdog: #{problem}"
        warn parser.banner
        return 1
      end

      Supervisor.new(options).run
    end

    def self.build_parser(options)
      OptionParser.new do |parser|
        parser.banner = 'Usage: ruby scripts/watchdog.rb [options] -- CMD [ARGS...]'
        parser.separator ''
        parser.separator 'Supervises CMD, records crash bundles and can run a repair command.'
        parser.separator ''
        parser.on('--log-dir DIR', 'Logs, status.json and crashes (default: .rubycog/watchdog)') do |value|
          options.log_dir = value
        end
        parser.on('--repair CMD', 'Shell command run after a crash; %{report} becomes the README path') do |value|
          options.repair = value
        end
        parser.on('--repair-timeout SECONDS', Float, 'Kill the repair command after this long (default: 900)') do |value|
          options.repair_timeout = value
        end
        parser.on('--max-restarts N', Integer, 'Restart budget before giving up (default: 5)') do |value|
          options.max_restarts = value
        end
        parser.on('--backoff SECONDS', Float, 'First restart delay, doubled up to 60s (default: 5)') do |value|
          options.backoff = value
        end
        parser.on('--stable-seconds SECONDS', Float, 'A run this long resets the restart counter (default: 120)') do |value|
          options.stable_seconds = value
        end
        parser.on('--no-restart', 'Record the crash but do not restart') do
          options.no_restart = true
        end
        parser.on('--once', 'Run the child once and exit (for tests; implies no restart)') do
          options.once = true
        end
        parser.on('--stop-file PATH', 'Exit cleanly when this file appears (Windows-friendly shutdown)') do |value|
          options.stop_file = value
        end
        parser.on('-h', '--help', 'Show this help') do
          options.help = true
        end
      end
    end

    def self.validate(options)
      return 'missing command: put the command after --' if options.command.empty?
      return '--log-dir must not be empty' if options.log_dir.to_s.strip.empty?
      return '--max-restarts must be >= 0' if options.max_restarts.negative?
      return '--backoff must be >= 0' if options.backoff.negative?
      return '--stable-seconds must be >= 0' if options.stable_seconds.negative?
      return '--repair-timeout must be > 0' if options.repair_timeout <= 0

      nil
    end
  end

  # Runs one supervised command at a time, writes state atomically and turns an
  # unexpected exit into a crash bundle.
  class Supervisor
    REPORT_PLACEHOLDER = '%{report}'
    LOG_TAIL_LINES = 120
    POLL_INTERVAL = 0.05
    MAX_BACKOFF = 60

    WINDOWS = RbConfig::CONFIG['host_os'].match?(/mswin|mingw|cygwin/)

    def initialize(options)
      @command = Array(options.command)
      @repair = options.repair.to_s.strip.empty? ? nil : options.repair
      @repair_timeout = options.repair_timeout
      @max_restarts = options.max_restarts
      @backoff = options.backoff
      @stable_seconds = options.stable_seconds
      @no_restart = options.no_restart
      @once = options.once
      @cwd = Dir.pwd
      @stop_file = options.stop_file && File.expand_path(options.stop_file, @cwd)
      @paths = Paths.new(options.log_dir)
      @restarts = 0
      @last_exit = nil
      @attempt = 0
      @stop_requested = false
    end

    # Runs until the child exits cleanly, the restart budget is spent, a repair
    # fails, or a shutdown is requested. Returns the process exit code.
    def run
      FileUtils.mkdir_p(@paths.log_dir)
      install_signal_traps
      loop do
        if stop_requested?
          write_status(state: 'stopped', pid: nil)
          return 0
        end

        @attempt += 1
        log_path = next_log_path
        started_at = Time.now.utc
        started_mono = monotonic
        begin
          pid = spawn_child(log_path)
        rescue SystemCallError => e
          warn "watchdog: could not start #{@command.first}: #{e.message}"
          write_status(state: 'stopped', pid: nil, error: "#{e.class}: #{e.message}")
          return 1
        end
        write_status(state: 'running', pid: pid, started_at: started_at.iso8601,
                     log_file: log_path)

        outcome = wait_for_child(pid)
        if outcome == :stopped
          terminate_child(pid)
          write_status(state: 'stopped', pid: nil, last_exit: @last_exit)
          return 0
        end

        status = outcome
        uptime = monotonic - started_mono
        @last_exit = exit_code(status)
        if status.success?
          write_status(state: 'stopped', pid: nil, last_exit: @last_exit,
                       started_at: started_at.iso8601, log_file: log_path)
          return 0
        end

        warn "watchdog: child exited with #{@last_exit} after #{format('%.2f', uptime)}s; collecting crash"
        write_status(state: 'crashing', pid: nil, last_exit: @last_exit,
                     started_at: started_at.iso8601, log_file: log_path)
        crash_dir = collect_crash(log_path: log_path, status: status, started_at: started_at,
                                  uptime: uptime)

        if @once
          write_status(state: 'stopped', pid: nil, last_exit: @last_exit,
                       crash_dir: crash_dir, log_file: log_path)
          return 1
        end

        # A run that survived long enough is not part of the same crash loop.
        @restarts = 0 if uptime >= @stable_seconds

        if @restarts >= @max_restarts
          warn "watchdog: restart budget exhausted (#{@max_restarts}); giving up"
          write_status(state: 'stopped', pid: nil, last_exit: @last_exit,
                       crash_dir: crash_dir, log_file: log_path,
                       note: 'max restarts exhausted')
          return 2
        end

        if @repair
          write_status(state: 'repairing', pid: nil, last_exit: @last_exit,
                       crash_dir: crash_dir, log_file: log_path)
          repair = run_repair(crash_dir)
          case repair
          when :stopped
            write_status(state: 'stopped', pid: nil, last_exit: @last_exit,
                         crash_dir: crash_dir, log_file: log_path)
            return 0
          when :failed
            write_status(state: 'stopped', pid: nil, last_exit: @last_exit,
                         crash_dir: crash_dir, log_file: log_path,
                         note: 'repair failed')
            return 1
          end
        end

        if @no_restart
          write_status(state: 'stopped', pid: nil, last_exit: @last_exit,
                       crash_dir: crash_dir, log_file: log_path)
          return 1
        end

        @restarts += 1
        delay = backoff_delay(@restarts)
        next unless wait_backoff(delay) == :stopped

        write_status(state: 'stopped', pid: nil, last_exit: @last_exit,
                     crash_dir: crash_dir, log_file: log_path)
        return 0
      end
    rescue StandardError => e
      warn "watchdog: fatal: #{e.class}: #{e.message}"
      warn e.backtrace.first(5).join("\n") if e.backtrace
      begin
        write_status(state: 'stopped', pid: nil, error: "#{e.class}: #{e.message}")
      rescue StandardError
        nil
      end
      1
    end

    private

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def windows?
      WINDOWS
    end

    def stop_requested?
      @stop_requested || (@stop_file && File.exist?(@stop_file))
    end

    def install_signal_traps
      %w[INT TERM].each do |signal|
        Signal.trap(signal) { @stop_requested = true }
      rescue ArgumentError, Errno::EINVAL
        nil
      end
    end

    def spawn_child(log_path)
      File.open(log_path, 'a') do |log|
        Process.spawn(*@command, out: log, err: log, chdir: @cwd)
      end
    end

    # Polls the child so a shutdown request is honoured within a poll interval.
    # Returns the Process::Status or :stopped.
    def wait_for_child(pid)
      loop do
        return :stopped if stop_requested?

        _waited_pid, status = Process.wait2(pid, Process::WNOHANG)
        return status if status

        sleep POLL_INTERVAL
      end
    end

    # Kills and reaps the direct child. On Windows Process.kill('KILL', pid)
    # terminates the child itself; grandchildren are out of scope.
    def terminate_child(pid)
      begin
        Process.kill('KILL', pid)
      rescue SystemCallError
        nil
      end
      begin
        Process.wait2(pid)
      rescue SystemCallError
        nil
      end
    end

    def exit_code(status)
      status.exitstatus || (status.termsig && 128 + status.termsig)
    end

    def backoff_delay(restart_number)
      delay = @backoff * (2**(restart_number - 1))
      [delay, MAX_BACKOFF].min
    end

    def wait_backoff(seconds)
      deadline = monotonic + seconds
      loop do
        return :stopped if stop_requested?

        remaining = deadline - monotonic
        return :ok if remaining <= 0

        sleep [remaining, POLL_INTERVAL].min
      end
    end

    def time_stamp
      Time.now.utc.strftime('%Y%m%dT%H%M%S%LZ')
    end

    def next_log_path
      stamp = time_stamp
      candidate = File.join(@paths.log_dir, "run-#{stamp}-#{@attempt}.log")
      suffix = 1
      while File.exist?(candidate)
        candidate = File.join(@paths.log_dir, "run-#{stamp}-#{@attempt}-#{suffix}.log")
        suffix += 1
      end
      candidate
    end

    def next_crash_dir
      base = File.join(@paths.crash_root, time_stamp)
      candidate = base
      suffix = 1
      while File.exist?(candidate)
        candidate = "#{base}-#{suffix}"
        suffix += 1
      end
      FileUtils.mkdir_p(candidate)
      candidate
    end

    def collect_crash(log_path:, status:, started_at:, uptime:)
      dir = next_crash_dir
      tail = log_tail(log_path)
      meta = {
        'crash_at' => Time.now.utc.iso8601,
        'exit_code' => exit_code(status),
        'signaled' => status.signaled?,
        'termsig' => status.termsig,
        'uptime_seconds' => uptime.round(3),
        'started_at' => started_at.iso8601,
        'command' => @command,
        'command_line' => display_command_line(@command),
        'cwd' => @cwd,
        'ruby_engine' => defined?(RUBY_ENGINE) ? RUBY_ENGINE : 'ruby',
        'ruby_version' => RUBY_VERSION,
        'ruby_platform' => RUBY_PLATFORM,
        'supervisor_pid' => Process.pid,
        'attempt' => @attempt,
        'restarts' => @restarts,
        'log_file' => log_path,
        'log_tail_lines' => tail.length,
        'log_tail' => tail,
        'git_head' => git_output('rev-parse', 'HEAD'),
        'git_status_porcelain' => git_output('status', '--porcelain'),
        'repair_command' => @repair,
        'repair_log' => @repair ? File.join(dir, 'repair.log') : nil
      }
      write_json(File.join(dir, 'meta.json'), meta)
      File.write(File.join(dir, 'log_tail.txt'), "#{tail.join("\n")}\n")
      File.write(File.join(dir, 'README.md'), crash_readme(meta, dir))
      dir
    rescue StandardError => e
      warn "watchdog: could not write crash bundle: #{e.class}: #{e.message}"
      nil
    end

    def log_tail(path)
      return [] unless path && File.exist?(path)

      text = File.binread(path).force_encoding(Encoding::UTF_8).scrub
      text.lines.map(&:chomp).last(LOG_TAIL_LINES)
    rescue SystemCallError, IOError
      []
    end

    def git_output(*args)
      output, _error, status = Open3.capture3('git', *args, chdir: @cwd)
      status.success? ? output.force_encoding(Encoding::UTF_8).scrub.chomp : nil
    rescue SystemCallError, IOError
      nil
    end

    # A copy-pasteable command line for the README. The raw argv is kept in
    # meta.json; this form only adds quotes where whitespace or shell
    # metacharacters make them necessary.
    def display_command_line(command)
      command.map do |argument|
        argument.match?(%r{[[:space:]"'&|<>^()%!]}) ? shell_quote(argument) : argument
      end.join(' ')
    end

    def git_status_text(meta)
      status = meta['git_status_porcelain']
      return '(git unavailable or not a git repository)' if status.nil?

      status.strip.empty? ? '(clean)' : status
    end

    # The README is the document the repair agent is told to read, so it must
    # carry every fact needed to reproduce the crash without opening meta.json.
    def crash_readme(meta, dir)
      exit_text = meta['exit_code'].to_s
      exit_text += " (killed by signal #{meta['termsig']})" if meta['signaled']
      log_tail = Array(meta['log_tail'])

      <<~MARKDOWN
        # RubyCog watchdog crash report

        The supervised process exited unexpectedly. This directory is a crash
        bundle written by `scripts/watchdog.rb`. Everything below is captured
        evidence for a repair agent, not a conclusion.

        - Crash time (UTC): #{meta['crash_at']}
        - Exit code: #{exit_text}
        - Uptime: #{format('%.3f', meta['uptime_seconds'])} s
        - Started at (UTC): #{meta['started_at']}
        - Command line: `#{meta['command_line']}`
        - Working directory: `#{meta['cwd']}`
        - Ruby: #{meta['ruby_engine']} #{meta['ruby_version']} (#{meta['ruby_platform']})
        - Supervisor pid: #{meta['supervisor_pid']}
        - Attempt: #{meta['attempt']} (restarts before this run: #{meta['restarts']})
        - Run log: `#{meta['log_file']}`
        - Crash bundle: `#{dir}`
        - Repair command: #{meta['repair_command'] ? "`#{meta['repair_command']}`" : '(not configured)'}
        - Repair output: #{meta['repair_log'] ? "`#{meta['repair_log']}`" : '(none)'}

        ## Git state

        - Git HEAD: `#{meta['git_head'] || 'unknown (git unavailable or not a git repository)'}`
        - `git status --porcelain`:

        ```text
        #{git_status_text(meta)}
        ```

        ## Last #{log_tail.length} lines of the run log

        ```text
        #{log_tail.join("\n")}
        ```

        ## What to do

        1. Read `meta.json` and the log tail above, then reproduce the failure
           with the command line shown.
        2. Find the smallest root cause. Do not hand-edit `Gemfile.lock`, do not
           commit, and do not weaken tests to make them pass.
        3. Run the relevant tests, then relaunch manually:
           `#{meta['command_line']}`.
      MARKDOWN
    end

    def run_repair(crash_dir)
      report = File.join(crash_dir, 'README.md')
      command = expand_repair(@repair, report)
      log_path = File.join(crash_dir, 'repair.log')
      env = {
        'WATCHDOG_CRASH_DIR' => crash_dir,
        'WATCHDOG_CRASH_REPORT' => report,
        'WATCHDOG_REPORT' => report
      }

      File.open(log_path, 'a') do |log|
        log.puts "=== repair started #{Time.now.utc.iso8601} ==="
        log.puts "command: #{command}"
        log.flush
        begin
          pid = Process.spawn(env, command, out: log, err: log, chdir: @cwd)
        rescue SystemCallError => e
          log.puts "repair could not start: #{e.class}: #{e.message}"
          warn "watchdog: repair command could not start: #{e.message}"
          return :failed
        end

        outcome = wait_for_repair(pid)
        case outcome
        when :stopped
          log.puts '=== repair interrupted by shutdown request ==='
          :stopped
        when :timeout
          log.puts "=== repair timed out after #{@repair_timeout}s ==="
          warn "watchdog: repair timed out after #{@repair_timeout}s; see #{log_path}"
          :failed
        else
          log.puts "=== repair finished #{Time.now.utc.iso8601} with exit #{exit_code(outcome)} ==="
          if outcome.success?
            :ok
          else
            warn "watchdog: repair exited with #{exit_code(outcome)}; see #{log_path}"
            :failed
          end
        end
      end
    end

    # Returns Process::Status, :stopped or :timeout.
    def wait_for_repair(pid)
      started = monotonic
      loop do
        if stop_requested?
          terminate_child(pid)
          return :stopped
        end
        if monotonic - started > @repair_timeout
          terminate_child(pid)
          return :timeout
        end

        _waited_pid, status = Process.wait2(pid, Process::WNOHANG)
        return status if status

        sleep POLL_INTERVAL
      end
    end

    # Replaces %{report} with a quoted path. If the placeholder sits inside an
    # already quoted argument (the usual prompt case) the path is inserted
    # verbatim, because the surrounding quotes already protect it.
    def expand_repair(template, report)
      output = +''
      index = 0
      while (found = template.index(REPORT_PLACEHOLDER, index))
        output << template[index...found]
        quote = open_quote_at(template, found)
        output << (quote ? escape_in_quote(report, quote) : shell_quote(report))
        index = found + REPORT_PLACEHOLDER.length
      end
      output << template[index..] if index < template.length
      output
    end

    # Returns the quote character still open at `limit`, or nil.
    def open_quote_at(command, limit)
      quote = nil
      index = 0
      while index < limit
        char = command[index]
        if quote == '"'
          if char == '\\' && command[index + 1] == '"'
            index += 2
            next
          elsif char == '"'
            quote = nil
          end
        elsif quote == "'"
          quote = nil if char == "'"
        elsif char == '\\' && !windows?
          index += 2
          next
        elsif char == '"'
          quote = '"'
        elsif char == "'" && !windows?
          quote = "'"
        end
        index += 1
      end
      quote
    end

    def escape_in_quote(value, quote)
      if quote == "'"
        value.gsub("'") { "'\\''" }
      elsif windows?
        value.gsub('"', '\\"')
      else
        value.gsub(/[\\"$`]/) { |char| "\\#{char}" }
      end
    end

    def shell_quote(value)
      if windows?
        "\"#{value.gsub('"', '\\"')}\""
      else
        "'#{value.gsub("'") { "'\\''" }}'"
      end
    end

    def write_json(path, payload)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.#{Process.pid}.tmp"
      File.write(tmp, JSON.pretty_generate(payload))
      File.rename(tmp, path)
    end

    def write_status(**fields)
      payload = {
        'state' => 'stopped',
        'pid' => nil,
        'started_at' => nil,
        'restarts' => @restarts,
        'last_exit' => @last_exit,
        'updated_at' => Time.now.utc.iso8601,
        'supervisor_pid' => Process.pid,
        'command' => @command,
        'log_dir' => @paths.log_dir,
        'stop_file' => @stop_file
      }.merge(fields.transform_keys(&:to_s))
      write_json(@paths.status_path, payload)
    rescue SystemCallError => e
      warn "watchdog: could not write status.json: #{e.message}"
    end
  end
end

exit RubyCogWatchdog::CLI.start(ARGV)
