# frozen_string_literal: true

require 'curses'
require 'io/console'
require 'rbconfig'
require_relative 'text'
require_relative 'eval_tool'
require_relative 'tool_preview'
require_relative 'self_iteration'
require_relative 'session'

module Rubycog
  class TUI
    WELCOME = 'A tiny Ruby agent. Ask anything; use Ruby through eval.'
    HELP = "/help  this help\n/yolo  toggle automatic tool approval\n/gc    free VM memory (run GC)\n/session  show session file and turns\n/compact  summarize the history to free context\n/self  show self-iteration history\n/restart  save and restart to load new code\n/clear  new conversation\n/quit   exit"
    STATS_INTERVAL = 2.0

    def initialize(agent, yolo: false, history: [], session: nil, self_iteration: nil, argv: ARGV)
      @agent = agent
      @session = session
      @self_iteration = self_iteration
      @argv = argv.dup
      @events = Queue.new
      @approvals = Queue.new
      turns = history_entries(history)
      @entries = [{ role: :info, text: WELCOME }]
      @entries.concat(turns)
      @entries << { role: :info, text: session_status(turns.size) } if session
      @entries << { role: :warning, text: 'YOLO: all tools run without approval.' } if yolo
      @input = +''
      @cursor = 0
      @bytes = +''.b
      @busy = false
      @approval = nil
      @scroll = 0
      @status = if !session
                  'ready'
                elsif turns.empty?
                  'new session'
                else
                  "resumed #{turns.size} turns"
                end
      @streaming = false
      @yolo = yolo
      @objects = nil
      @memory = nil
      @stats_at = nil
      @shown_code = nil
      @source_digest = source_snapshot
      @source_stale = false
    end

    def run
      Curses.init_screen
      Curses.start_color if Curses.has_colors?
      Curses.use_default_colors if Curses.has_colors?
      Curses.noecho
      Curses.cbreak
      Curses.curs_set(1)
      @window = Curses.stdscr
      @window.keypad = true
      @window.timeout = 50
      init_colors
      draw

      action = nil
      loop do
        key = normalize_key(@window.getch)
        drain_events
        action = handle_key(key)
        break if action == :quit || action == :restart

        draw
      end
    ensure
      if @busy
        @agent.cancel
        @worker&.join(1)
      end
      Curses.close_screen
      exec(RbConfig.ruby, $PROGRAM_NAME, *@argv) if action == :restart
    end

    private

    def session_status(count)
      return '' unless @session&.path

      count.positive? ? "Resumed #{count} turns from #{@session.path}" : "New session: #{@session.path}"
    end

    def session_report
      return 'session: none' unless @session

      count = @session.respond_to?(:messages) ? @session.messages.size : 0
      "#{@session.path} · #{count} turns"
    end

    # Prior turns are shown under the welcome banner after a restart.
    def history_entries(history)
      Session.extract(history).map { |message| { role: message['role'].to_sym, text: message['content'] } }
    end

    # Self-edits change files on disk; the running process keeps the old
    # classes. Track the snapshot so the footer can ask for a restart.
    def source_snapshot
      paths = Dir[File.join(Rubycog.root, 'lib', '**', '*.rb')]
      paths += [File.join(Rubycog.root, 'Gemfile'), File.join(Rubycog.root, 'bin', 'rubycog')]
      paths.sort.each_with_object({}) do |path, snapshot|
        next unless File.file?(path)

        stat = File.stat(path)
        snapshot[path] = [stat.mtime.to_f, stat.size]
      end
    rescue SystemCallError
      {}
    end

    def refresh_source_state
      @source_stale = source_snapshot != @source_digest
    rescue StandardError
      @source_stale = false
    end

    def init_colors
      return unless Curses.has_colors?

      Curses.init_pair(1, Curses::COLOR_CYAN, -1)
      Curses.init_pair(2, Curses::COLOR_GREEN, -1)
      Curses.init_pair(3, Curses::COLOR_YELLOW, -1)
      Curses.init_pair(4, Curses::COLOR_RED, -1)
    end

    def normalize_key(key)
      key.is_a?(String) ? key.ord : key
    end

    def handle_key(key)
      return :quit if key == 3 && !@busy
      if key == 3
        approve(false) if @approval
        @agent.cancel
        @status = 'cancelling'
        return
      end
      return approve(true) if @approval && [121, 89].include?(key)
      return approve(false) if @approval && [110, 78].include?(key)
      return if @busy

      case key
      when 10, 13 then submit
      when 12 then draw
      when Curses::KEY_LEFT then @cursor = [@cursor - 1, 0].max
      when Curses::KEY_RIGHT then @cursor = [@cursor + 1, @input.length].min
      when Curses::KEY_HOME then @cursor = 0
      when Curses::KEY_END then @cursor = @input.length
      when Curses::KEY_BACKSPACE, 8, 127
        @input.slice!(@cursor - 1) if @cursor.positive?
        @cursor = [@cursor - 1, 0].max
      when Curses::KEY_DC then @input.slice!(@cursor)
      when 21 then @input.slice!(0...@cursor) && @cursor = 0
      when 11 then @input.slice!(@cursor..)
      when Curses::KEY_PPAGE then @scroll += 5
      when Curses::KEY_NPAGE then @scroll = [@scroll - 5, 0].max
      else append_input(key)
      end
      nil
    end

    def append_input(key)
      return unless key.is_a?(Integer) && key.between?(32, 255)

      @bytes << key
      text = @bytes.dup.force_encoding(Encoding::UTF_8)
      return unless text.valid_encoding?

      @input.insert(@cursor, text)
      @cursor += text.length
      @bytes.clear
    end

    def submit
      message = @input.strip
      return if message.empty?

      case message
      when '/quit', '/exit' then return :quit
      when '/restart'
        return :restart if save_session
      when '/clear'
        if @agent.chat.complete?
          @agent.reset
          @entries = [{ role: :info, text: 'New conversation.' }]
          @entries << { role: :warning, text: 'YOLO: all tools run without approval.' } if @yolo
        else
          @entries << { role: :info, text: 'Finish the current step before clearing.' }
        end
      when '/help'
        @entries << { role: :info, text: HELP }
      when '/session'
        @entries << { role: :info, text: session_report }
      when '/compact'
        if @agent.chat.complete?
          @busy = true
          @status = 'compacting'
          @worker = Thread.new { compact_conversation }
        else
          @entries << { role: :info, text: 'Finish the current step before compacting.' }
        end
      when '/self'
        text = @self_iteration ? @self_iteration.to_text : 'self-iteration: not configured'
        @entries << { role: :info, text: text }
      when '/gc' then collect_garbage
      when '/yolo'
        @yolo = !@yolo
        if @yolo
          @entries << { role: :warning, text: 'YOLO on: all tools run without approval.' }
        else
          @entries << { role: :info, text: 'YOLO off: eval requires approval.' }
        end
      else
        @entries << { role: :user, text: message }
        @busy = true
        @status = 'thinking'
        @scroll = 0
        @worker = Thread.new { converse(message) }
      end
      @input.clear
      @cursor = 0
      nil
    end

    def converse(message)
      response = @agent.ask(message) { |event| @events << event }
      while response && @agent.chat.awaiting_approval?
        call = @agent.chat.pending_approvals.first
        approved = resolve_approval(call)
        @agent.resolve(call, approved)
        response = @agent.complete { |event| @events << event }
      end
    rescue Interrupt
      raise
    rescue Exception => e # rubocop:disable Lint/RescueException
      @events << { type: :error, payload: "#{e.class}: #{e.message}" }
    ensure
      @events << { type: :done, payload: nil }
    end

    def compact_conversation
      summary = @agent.compact { |event| @events << event }
      text = if summary
               "Compacted the earlier turns into a #{summary.length}-character summary."
             else
               'Nothing to compact yet: the history is short, or a step is still open.'
             end
      @events << { type: :info, payload: text }
    rescue Interrupt
      raise
    rescue Exception => e # rubocop:disable Lint/RescueException
      @events << { type: :error, payload: "#{e.class}: #{e.message}" }
    ensure
      @events << { type: :done, payload: nil }
    end

    def resolve_approval(call)
      if @yolo
        @events << { type: :auto_approval, payload: nil }
        return true
      end

      @events << { type: :approval, payload: call }
      @events << { type: :status, payload: 'waiting for approval' }
      @approvals.pop
    end

    def approve(approved)
      @events << { type: :approval_decision, payload: approved }
      @approvals << approved
      @approval = nil
    end

    def drain_events
      until @events.empty?
        event = @events.pop(true)
        payload = event[:payload]
        case event[:type]
        when :text then append_text(payload)
        when :text_end then @streaming = false
        when :tool_call then show_code(payload[:code])
        when :tool_result
          @shown_code = nil
          @entries << { role: :result, text: payload.to_s }
        when :status then @status = payload
        when :info then @entries << { role: :info, text: payload.to_s }
        when :error
          @entries << { role: :error, text: payload }
          @status = 'ready'
        when :approval
          @approval = payload
          show_code(ToolPreview.for(payload))
        when :auto_approval
          @entries << { role: :info, text: 'tool auto-approved (yolo)' }
        when :approval_decision
          @entries << { role: :info, text: payload ? 'eval approved' : 'eval denied' }
        when :done
          @busy = false
          @status = 'ready'
          @streaming = false
        end
      end
    end

    # Approval and the tool call both carry the code; show it once per call.
    def show_code(code)
      code = code.to_s
      return if code.empty? || code == @shown_code

      @shown_code = code
      @entries << { role: :tool, text: code }
    end

    def append_text(text)
      unless @streaming
        @entries << { role: :assistant, text: +'' }
        @streaming = true
      end
      @entries.last[:text] << text
    end

    def draw
      return unless @window

      @window.erase
      height = @window.maxy
      width = @window.maxx
      if height < 6 || width < 24
        put(0, 0, 'Terminal too small (minimum 24x6)', width, 4)
      else
        draw_header(width)
        draw_transcript(height, width)
        draw_footer(height, width)
        draw_input(height, width)
      end
      @window.refresh
    rescue Curses::Error
      # A resize can invalidate a draw between measuring and writing.
    end

    def draw_header(width)
      model = @agent.chat.model.id
      put(0, 1, 'RubyCog', width - 2, 2, Curses::A_BOLD)
      put(0, 10, model, width - 11, 0)
      draw_cwd(width, 10 + Text.width(model) + 2)
      put(1, 0, '─' * width, width, 1)
    end

    def draw_cwd(width, left)
      room = width - 2 - left
      return if room < 8

      path = truncate_path(Dir.pwd, room)
      put(0, width - 1 - Text.width(path), path, room, 1)
    end

    def truncate_path(path, room)
      return path if Text.width(path) <= room
      return '' if room < 2

      "…#{Text.slice(path, Text.width(path) - (room - 1), room - 1)}"
    end

    def draw_transcript(height, width)
      rows = @entries.flat_map do |entry|
        label, color = labels.fetch(entry[:role])
        lines = [[label, color, Curses::A_BOLD]]
        lines.concat(Text.wrap(entry[:text], width - 4).map { |line| ["  #{line}", 0, 0] })
        lines << ['', 0, 0]
      end
      body_height = height - 5
      @scroll = [@scroll, [rows.length - body_height, 0].max].min
      visible = rows.last(body_height + @scroll).first(body_height)
      visible.each_with_index { |(text, color, attribute), i| put(i + 2, 1, text, width - 2, color, attribute) }
    end

    def draw_footer(height, width)
      mode = @yolo ? '  ·  YOLO' : ''
      text = if @approval
               "Run #{@approval.name}? [y] approve once  [n] deny"
             elsif @source_stale
               'code changed — /restart to apply'
             elsif @busy
               "#{@status}#{mode}  ·  Ctrl-C cancel"
             else
               "#{@status}#{mode}  ·  Enter send  ·  /help  ·  Ctrl-C quit"
             end
      put(height - 3, 1, text, width - 2, @approval ? 3 : 0)
      draw_stats(height, width, Text.width(text))
      put(height - 2, 0, '─' * width, width, 1)
    end

    def draw_stats(height, width, left_width)
      refresh_stats
      text = stats_text
      return if text.empty?

      room = width - left_width - 4
      return if room < Text.width(text)

      put(height - 3, width - 1 - Text.width(text), text, room, 0)
    end

    def stats_text
      return '' if @objects.nil?

      "obj #{format_count(@objects)} · mem #{format_bytes(@memory)}"
    end

    def stats_snapshot
      { objects: GC.stat(:heap_live_slots), memory: memory_bytes }
    rescue StandardError
      { objects: nil, memory: nil }
    end

    def refresh_stats(force: false)
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return if !force && @stats_at && now - @stats_at < STATS_INTERVAL

      @stats_at = now
      refresh_source_state
      snapshot = stats_snapshot
      @objects = snapshot[:objects]
      @memory = snapshot[:memory]
    end

    def save_session
      return true unless @session

      @session.save(@agent.chat.messages)
      true
    rescue StandardError => e
      @entries << { role: :error, text: "session save failed: #{e.class}: #{e.message}" }
      false
    end

    def collect_garbage
      before = stats_snapshot
      GC.start
      refresh_stats(force: true)
      @entries << { role: :info, text: gc_report(before) }
    end

    def gc_report(before)
      freed = before[:objects] && @objects ? [before[:objects] - @objects, 0].max : nil
      freed_text = freed ? "freed #{format_count(freed)} objects" : 'freed objects'
      "GC complete: #{freed_text} · mem #{format_bytes(before[:memory])} → #{format_bytes(@memory)}"
    end

    def memory_bytes
      output = IO.popen(['ps', '-o', 'rss=', '-p', Process.pid.to_s], &:read)
      kilobytes = output.to_i
      return kilobytes * 1024 if kilobytes.positive?

      heap_bytes
    rescue SystemCallError
      heap_bytes
    end

    def heap_bytes
      GC.stat(:heap_allocated_pages) * GC::INTERNAL_CONSTANTS.fetch(:HEAP_PAGE_SIZE, 65_536)
    end

    def format_count(count)
      count.to_s.gsub(/\B(?=(\d{3})+(?!\d))/, ',')
    end

    def format_bytes(bytes)
      return 'n/a' unless bytes

      if bytes >= 1024**3
        format('%.1f GB', bytes / 1024.0**3)
      elsif bytes >= 1024**2
        format('%.1f MB', bytes / 1024.0**2)
      else
        format('%.0f KB', bytes / 1024.0)
      end
    end

    def draw_input(height, width)
      prompt = '> '
      room = width - prompt.length - 1
      offset = [Text.width(@input[0...@cursor]) - room + 1, 0].max
      put(height - 1, 0, prompt, width, 1, Curses::A_BOLD)
      put(height - 1, prompt.length, Text.slice(@input, offset, room), room, 0)
      Curses.curs_set(@busy ? 0 : 1)
      cursor = prompt.length + Text.width(@input[0...@cursor]) - offset
      @window.setpos(height - 1, [cursor, width - 1].min)
    end

    def labels
      {
        user: ['You', 1], assistant: ['RubyCog', 2], tool: ['eval', 3],
        result: ['result', 3], error: ['Error', 4], warning: ['Warning', 3],
        info: ['·', 0]
      }
    end

    def put(y, x, text, max_width, color = 0, attribute = 0)
      return if max_width <= 0

      @window.attron(Curses.color_pair(color) | attribute) do
        @window.setpos(y, x)
        @window.addstr(Text.slice(text, 0, max_width))
      end
    end
  end
end
