# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'time'
require_relative 'tool_preview'

module Rubycog
  # Runs the agent without curses so a supervisor can drive it from a pipe.
  #
  # It consumes the same event stream as the TUI, prints one plain-text line per
  # event, auto-approves every tool call, and either answers one prompt
  # (`--task`) or polls an inbox directory for `*.txt` task files (`--daemon`).
  # Conversation restore and saving stay in Rubycog::Session through the Agent,
  # so a headless run and a TUI run share the same session file.
  class Headless
    DEFAULT_INBOX = File.join('.rubycog', 'headless', 'inbox').freeze
    DEFAULT_HEARTBEAT = File.join('.rubycog', 'headless', 'heartbeat.json').freeze
    DEFAULT_INTERVAL = 5
    # Long tool output is trimmed so one run_tests result cannot flood a log.
    MAX_RESULT_CHARS = 4_000
    # Tool previews are folded onto the single approval line.
    MAX_PREVIEW_CHARS = 200

    attr_reader :tasks_done

    # Wires the runner to an agent and to the paths a supervisor watches.
    #
    # `stdout` carries the event stream and `stderr` the startup banner and
    # fatal backtraces. The defaults match the CLI surface, so tests only have
    # to override the directories.
    def initialize(agent, stdout: $stdout, stderr: $stderr, inbox: DEFAULT_INBOX,
                   heartbeat: DEFAULT_HEARTBEAT, interval: DEFAULT_INTERVAL)
      @agent = agent
      @out = stdout
      @err = stderr
      @inbox = inbox
      @heartbeat = heartbeat
      @interval = interval
      @started_at = Time.now.utc.iso8601
      @tasks_done = 0
      @streaming = false
      @failed = false
      @stopping = false
      @previous_handlers = nil
    end

    # Runs the requested mode and returns a process exit status.
    #
    # A prompt given with `task` is answered first; `daemon` then keeps polling
    # the inbox. Anything that escapes task handling is fatal: the backtrace
    # goes to stderr and the status is 1.
    def run(task: nil, daemon: false)
      banner
      status = 0
      status = run_task(task) ? 0 : 1 if task
      return run_daemon if daemon

      status
    rescue Interrupt
      close_stream
      log('[interrupted]')
      0
    rescue Exception => e # rubocop:disable Lint/RescueException
      close_stream
      @err.puts "rubycog: #{e.class}: #{e.message}"
      Array(e.backtrace).each { |line| @err.puts "  #{line}" }
      1
    end

    # Processes every inbox task file once and refreshes the heartbeat.
    #
    # Returns how many tasks have succeeded so far. A task file that raises is
    # moved to inbox/failed and does not stop the remaining files.
    def tick
      write_heartbeat
      task_files.each do |path|
        process_file(path)
        write_heartbeat
      end
      @tasks_done
    end

    private

    # Prints one startup line on stderr so a supervisor log names the process.
    def banner
      @err.puts "[startup] rubycog headless pid=#{Process.pid} model=#{model_name} ruby=#{RUBY_VERSION}"
      @err.flush if @err.respond_to?(:flush)
    end

    # Model actually in use, with the configured default as the fallback.
    def model_name
      name = @agent.model if @agent.respond_to?(:model)
      name = RubyLLM.config.default_model if name.to_s.empty? && defined?(RubyLLM)
      name.to_s.empty? ? 'unknown' : name
    end

    # Polls the inbox until SIGINT or SIGTERM sets the stop flag.
    def run_daemon
      prepare_dirs
      log("[daemon] watching #{@inbox} every #{@interval}s")
      install_signals
      until @stopping
        tick
        break if @stopping

        sleep @interval
      end
      log('[daemon] stopped')
      0
    ensure
      restore_signals
    end

    # Answers one prompt, auto-approving each tool round, and reports success.
    def run_task(message)
      @failed = false
      @streaming = false
      log("[task] #{inline(message)}")
      response = @agent.ask(message) { |event| handle(event) }
      while response && awaiting_approval?
        call = @agent.chat.pending_approvals.first
        break unless call

        approve(call)
        response = @agent.complete { |event| handle(event) }
      end
      close_stream
      log(@failed ? '[done] failed' : '[done] ok')
      !@failed
    rescue Interrupt
      close_stream
      raise
    rescue Exception => e # rubocop:disable Lint/RescueException
      close_stream
      log("[error] #{e.class}: #{e.message}")
      false
    end

    # True while the chat holds a tool call that needs an approval decision.
    def awaiting_approval?
      chat = @agent.chat
      chat.respond_to?(:awaiting_approval?) && chat.awaiting_approval?
    end

    # Records the approval line and lets the tool run; headless never asks.
    def approve(call)
      log("[approval] auto-approved #{call.name}: #{inline(ToolPreview.for(call))}")
      @agent.resolve(call, true)
    end

    # Prints one agent event in the plain-text stream supervisors parse.
    def handle(event)
      payload = event[:payload]
      case event[:type]
      when :text then write_text(payload)
      when :text_end then close_stream
      when :status then log("[status] #{payload}")
      when :tool_call then log_tool_call(payload)
      when :tool_result then log_result(payload)
      when :error
        @failed = true
        log("[error] #{payload}")
      end
    end

    # Shows the tool name and the same preview the TUI approval prompt uses.
    def log_tool_call(payload)
      log("[tool] #{payload[:name]}")
      payload[:code].to_s.each_line { |line| @out.puts("  #{line.chomp}") }
      flush
    end

    # Shows tool output indented, trimming the tail so logs stay readable.
    def log_result(payload)
      text = payload.to_s
      log('[result]')
      shown = if text.length > MAX_RESULT_CHARS
                "#{text[0, MAX_RESULT_CHARS]}\n[truncated #{text.length - MAX_RESULT_CHARS} chars]"
              else
                text
              end
      shown.each_line { |line| @out.puts("  #{line.chomp}") }
      flush
    end

    # Writes streamed answer text as-is so chunks join on the same line.
    def write_text(text)
      @streaming = true
      @out.write(text)
      flush
    end

    # Ends streamed text with a newline so the next tag starts on its own line.
    def close_stream
      return unless @streaming

      @streaming = false
      @out.puts
      flush
    end

    # Writes one line, closing any open streamed text first.
    def log(line)
      close_stream
      @out.puts(line)
      flush
    end

    # Flushes when the sink supports it, keeping piped logs live.
    def flush
      @out.flush if @out.respond_to?(:flush)
    end

    # Runs one inbox file and files it under done or failed.
    def process_file(path)
      message = File.read(path).strip
      raise ArgumentError, 'task file is empty' if message.empty?

      success = run_task(message)
      @tasks_done += 1 if success
      target = success ? done_dir : failed_dir
      move_to(path, target)
      log("[inbox] #{File.basename(path)} -> #{success ? 'done' : 'failed'}")
    rescue StandardError => e
      log("[error] #{File.basename(path)}: #{e.class}: #{e.message}")
      move_to(path, failed_dir)
    end

    # Moves a task file into `dir`, avoiding a clash with an older run.
    def move_to(path, dir)
      FileUtils.mkdir_p(dir)
      FileUtils.mv(path, unique_path(File.join(dir, File.basename(path))))
    rescue SystemCallError => e
      log("[error] cannot move #{File.basename(path)}: #{e.class}: #{e.message}")
    end

    # Appends a counter when a file with the same name is already filed.
    def unique_path(path)
      return path unless File.exist?(path)

      ext = File.extname(path)
      base = path.delete_suffix(ext)
      index = 1
      index += 1 while File.exist?("#{base}-#{index}#{ext}")
      "#{base}-#{index}#{ext}"
    end

    # Creates the inbox, its done/failed directories and the heartbeat dir.
    def prepare_dirs
      FileUtils.mkdir_p([@inbox, done_dir, failed_dir, File.dirname(@heartbeat)])
    end

    # Where successfully processed task files are kept.
    def done_dir
      File.join(@inbox, 'done')
    end

    # Where task files that raised are kept for inspection.
    def failed_dir
      File.join(@inbox, 'failed')
    end

    # Inbox task files in name order; subdirectories are not tasks.
    def task_files
      Dir.glob(File.join(@inbox, '*.txt')).sort
    end

    # Writes pid/started_at/last_tick/tasks_done atomically for a watchdog.
    def write_heartbeat
      FileUtils.mkdir_p(File.dirname(@heartbeat))
      payload = {
        'pid' => Process.pid,
        'started_at' => @started_at,
        'last_tick' => Time.now.utc.iso8601,
        'tasks_done' => @tasks_done
      }
      tmp = "#{@heartbeat}.#{Process.pid}.tmp"
      File.write(tmp, "#{JSON.pretty_generate(payload)}\n")
      File.rename(tmp, @heartbeat)
    rescue SystemCallError => e
      log("[error] heartbeat: #{e.class}: #{e.message}")
    end

    # Sets a stop flag instead of raising, so the task in flight can finish.
    def install_signals
      @previous_handlers = {}
      %w[INT TERM].each do |signal|
        @previous_handlers[signal] = Signal.trap(signal) { @stopping = true }
      end
    end

    # Puts the process back the way another caller expected it.
    def restore_signals
      return unless @previous_handlers

      @previous_handlers.each { |signal, handler| Signal.trap(signal, handler) }
      @previous_handlers = nil
    rescue ArgumentError
      nil
    end

    # Folds a possibly multi-line preview onto one line for status logs.
    def inline(text)
      folded = text.to_s.gsub(/\s+/, ' ').strip
      folded.length > MAX_PREVIEW_CHARS ? "#{folded[0, MAX_PREVIEW_CHARS]}..." : folded
    end
  end
end
