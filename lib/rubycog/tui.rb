# frozen_string_literal: true

require 'curses'
require 'io/console'
require 'rbconfig'
require 'time'
require_relative 'text'
require_relative 'eval_tool'
require_relative 'tool_preview'
require_relative 'self_iteration'
require_relative 'session'

module Rubycog
  # Curses UI: transcript, input, approvals, session footer and restart.
  class TUI
    WELCOME = 'A tiny Ruby agent. Ask anything; use Ruby through eval.'
    HELP = "/help  this help\n/yolo  toggle automatic tool approval\n/gc    free VM memory (run GC)\n/reset-eval  drop eval local variables\n/session  show session file and turns\n/compact  summarize the history to free context\n/self  show self-iteration history\n/restart  save and restart to load new code\n/clear  new conversation\n/quit   exit\nCtrl-F  search the transcript"
    STATS_INTERVAL = 2.0
    TICK_INTERVAL = 0.25 # footer clock repaint while a turn runs
    CODE_COLOR = 5
    # Running-status pulse: the footer status word walks a colour ramp so a long
    # turn visibly breathes instead of looking frozen. Frames advance with the
    # monotonic clock; TICK_INTERVAL throttles the repaints that show them.
    PULSE_STEP = 0.3 # seconds per frame
    PULSE_BASE = 10 # first pair allocated, clear of the label and code pairs
    PULSE_RAMP_256 = [30, 37, 44, 51, 44, 37].freeze # deep teal up to bright cyan
    PULSE_RAMP_8 = [Curses::COLOR_BLUE, Curses::COLOR_CYAN,
                    Curses::COLOR_WHITE, Curses::COLOR_CYAN].freeze
    SEARCH_KEY = 6 # Ctrl-F
    WHEEL_STEP = 3 # rows per wheel notch
    # ncurses stores button n's state in 6-bit slots, press being bit 1. Wheel
    # down is BUTTON5, which ncurses only learnt in 6.1: on 6.0 the binding has
    # no BUTTON5 constant and ncurses swallows those bytes (measured: wheel up
    # arrives as KEY_MOUSE with bstate 524288, wheel down arrives as nothing).
    WHEEL_SUPPORTED = Curses.const_defined?(:BUTTON5_PRESSED)
    WHEEL_UP = 2 << ((4 - 1) * 6)
    WHEEL_DOWN = 2 << ((5 - 1) * 6)
    # Ruby token styles for eval code. init_colors allocates the matching
    # colour pairs; when the terminal refuses them @ruby_pairs turns false and
    # these styles fall back to the plain code colour.
    STYLES = { code: [CODE_COLOR, 0], heading: [0, Curses::A_BOLD], bold: [0, Curses::A_BOLD],
               italic: [0, Curses::A_UNDERLINE], inline_code: [CODE_COLOR, 0],
               keyword: [6, Curses::A_BOLD], string: [7, 0], comment: [8, 0],
               number: [9, 0], constant: [16, Curses::A_BOLD], symbol: [17, 0],
               method: [18, 0] }.freeze
    RUBY_PAIRS = { keyword: [6, Curses::COLOR_CYAN], string: [7, Curses::COLOR_GREEN],
                   comment: [8, Curses::COLOR_BLUE], number: [9, Curses::COLOR_YELLOW],
                   constant: [16, Curses::COLOR_MAGENTA], symbol: [17, Curses::COLOR_RED],
                   method: [18, Curses::COLOR_CYAN] }.freeze
    LABELS = {
      user: ['You', 1], assistant: ['RubyCog', 2], tool: ['eval', 3],
      result: ['result', 3], error: ['Error', 4], warning: ['Warning', 3],
      info: ['·', 0]
    }.freeze

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
      @top = nil
      @row_count = nil
      @body_height = nil
      @body_width = nil
      # Search prompt state: the query while Ctrl-F is open, the row the search
      # started from, and the last result so the footer can report it.
      @search = nil
      @search_anchor = 0
      @search_found = nil
      @match_count = 0
      @search_bytes = +''.b
      @status = if !session
                  'ready'
                elsif turns.empty?
                  'new session'
                else
                  "resumed #{turns.size} turns"
                end
      @streaming = false
      @pulse_pairs = nil # filled by init_colors when the terminal has colours
      @ruby_pairs = false # token colours, see init_ruby_pairs
      @yolo = yolo
      @objects = nil
      @memory = nil
      @stats_at = nil
      # Turn timing: when the current turn started and which transcript entry
      # opened it, so the finished duration lands on the right entry.
      @turn_started_at = nil
      @turn_index = nil
      @tick_at = nil
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
      enable_mouse
      start_stats_sampler
      draw

      action = nil
      loop do
        key = normalize_key(@window.getch)
        changed = drain_events.positive?
        action = handle_key(key)
        break if action == :quit || action == :restart

        # The 50ms read timeout wakes the loop even when nothing happened;
        # redrawing then only burns CPU proportional to transcript size. The
        # exception is the running turn clock, which needs repaints of its own.
        draw if key || changed || live_tick?
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

    # Prior turns are shown under the welcome banner after a restart, with the
    # time the session file recorded for each one.
    def history_entries(history)
      Session.extract(history).map do |message|
        { role: message['role'].to_sym, text: message['content'], at: parse_clock(message['at']) }
      end
    end

    # Reads a stored ISO8601 timestamp, or nil when it is missing or unreadable.
    def parse_clock(value)
      value.is_a?(String) ? Time.iso8601(value) : nil
    rescue ArgumentError
      nil
    end

    # "14:32" for today, "05-03 14:32" for older turns, so a conversation
    # resumed from last week still reads correctly without wasting columns.
    def format_clock(at)
      return '' unless at

      local = at.getlocal
      now = Time.now
      return local.strftime('%H:%M') if local.year == now.year && local.yday == now.yday

      local.strftime('%m-%d %H:%M')
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
      Curses.init_pair(CODE_COLOR, Curses::COLOR_MAGENTA, -1)
      @pulse_pairs = init_pulse_pairs
      @ruby_pairs = init_ruby_pairs
    end

    # Allocates one pair per Ruby token style; false when the terminal refuses
    # them, which makes the tokens read as plain code.
    def init_ruby_pairs
      RUBY_PAIRS.each_value { |pair, color| Curses.init_pair(pair, color, -1) }
      true
    rescue StandardError
      false
    end

    # Allocates one colour pair per pulse frame and returns their numbers, or an
    # empty list when the terminal refuses them (monochrome, too few pairs).
    def init_pulse_pairs
      ramp = Curses.colors >= 256 ? PULSE_RAMP_256 : PULSE_RAMP_8
      ramp.each_with_index.map do |color, index|
        pair = PULSE_BASE + index
        Curses.init_pair(pair, color, -1)
        pair
      end
    rescue StandardError
      []
    end

    def normalize_key(key)
      key.is_a?(String) ? key.ord : key
    end

    def handle_key(key)
      return approve(true) if @approval && [121, 89].include?(key)
      return approve(false) if @approval && [110, 78].include?(key)
      return if search_key(key) # the search prompt owns the keyboard while open
      return :quit if key == 3 && !@busy
      if key == 3
        approve(false) if @approval
        @agent.cancel
        @status = 'cancelling'
        return
      end
      return if mouse_key(key) # wheel scrolling, also while a turn runs
      return if scroll_key(key) # reading history must work while a turn runs
      return if @busy

      case key
      when 10, 13 then return submit
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
      else append_input(key)
      end
      nil
    end

    def append_input(key)
      text = next_char(@bytes, key)
      return unless text

      @input.insert(@cursor, text)
      @cursor += text.length
    end

    # Collects raw bytes from curses and returns a complete UTF-8 character, or
    # nil while the bytes of a multi-byte character are still arriving.
    def next_char(bytes, key)
      return nil unless key.is_a?(Integer) && key.between?(32, 255)

      bytes << key
      text = bytes.dup.force_encoding(Encoding::UTF_8)
      return nil unless text.valid_encoding?

      bytes.clear
      text
    end

    def submit
      message = @input.strip
      if message.empty?
        @top = nil # an empty Enter jumps back to the newest output
        return
      end

      @search = nil # sending anything closes an open search prompt
      case message
      when '/quit', '/exit' then return :quit
      when '/restart'
        return :restart if save_session
      when '/clear'
        if @agent.chat.complete?
          @agent.reset
          @entries = [{ role: :info, text: 'New conversation.' }]
          @top = nil
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
      when '/reset-eval'
        @agent.reset_eval
        GC.start
        @entries << { role: :info,
                      text: 'eval locals cleared and GC ran; methods, constants, globals, threads and open resources may remain' }
      when '/yolo'
        @yolo = !@yolo
        if @yolo
          @entries << { role: :warning, text: 'YOLO on: all tools run without approval.' }
        else
          @entries << { role: :info, text: 'YOLO off: eval requires approval.' }
        end
      else
        @entries << { role: :user, text: message, at: Time.now }
        start_turn
        @busy = true
        @status = 'thinking'
        @top = nil
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

    # Returns how many events were handled so the loop can redraw only when
    # the screen actually changed.
    def drain_events
      handled = 0
      until @events.empty?
        event = @events.pop(true)
        handled += 1
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
          finish_turn
        end
      end
      handled
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
        @entries << { role: :assistant, text: +'', at: Time.now }
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
      rows = @entries.flat_map { |entry| entry_rows(entry, width) }
      body_height = height - 5
      @body_height = body_height
      @body_width = width
      @row_count = rows.length
      top = transcript_top
      visible = rows[top, body_height] || []
      visible.each_with_index { |(row, color, attribute), i| put_row(i + 2, 1, row, width - 2, color, attribute) }
    end

    # Label row pieces, joined by the caller: the role name, then when the
    # message was written, then how long the turn took. Tool and info rows
    # carry a name only.
    def label_parts(name, entry)
      parts = [name]
      clock = format_clock(entry[:at])
      parts << clock unless clock.empty?
      parts << format_duration(entry[:elapsed]) if entry[:elapsed]
      parts
    end

    # The label row, the wrapped text and the blank spacer for one entry, as
    # [row, colour, attribute] triples. Kept next to the layout cache and reused
    # while body_rows hands back the same array, so a keystroke only allocates
    # for the entry that is still streaming.
    def entry_rows(entry, width)
      body = body_rows(entry, width)
      cached = entry[:triples]
      return cached[:triples] if cached && cached[:rows].equal?(body)

      label, color = LABELS.fetch(entry[:role])
      label = label_parts(label, entry).join(' · ')
      triples = [[Markdown::Row.new([[+label, nil]]), color, Curses::A_BOLD]] +
                body.map { |row| [row, 0, 0] } +
                [[Markdown::Row.new, 0, 0]]
      entry[:triples] = { rows: body, triples: triples }
      triples
    end

    # Top row of the transcript viewport.
    #
    # @top is nil while the view follows the newest rows. Scrolling back stores
    # an absolute row index instead of a distance from the bottom, so rows that
    # stream in below do not push the text being read off the screen. Landing on
    # the last page re-pins the view to the tail.
    def transcript_top
      max_top = [@row_count - @body_height, 0].max
      return max_top if @top.nil?

      top = [@top, max_top].min
      @top = top >= max_top ? nil : top
      top
    end

    # Moves the viewport; a positive delta scrolls towards older rows.
    def scroll_by(delta)
      return unless @row_count && @body_height

      max_top = [@row_count - @body_height, 0].max
      top = ((@top || max_top) - delta).clamp(0, max_top)
      @top = top >= max_top ? nil : top
    end

    # Scroll keys stay available while a turn runs so history can be read
    # during long tool calls. Returns true when the key was a scroll key.
    def scroll_key(key)
      return false unless @window

      page = [@body_height.to_i - 1, 1].max
      case key
      when Curses::KEY_UP then scroll_by(1)
      when Curses::KEY_DOWN then scroll_by(-1)
      when Curses::KEY_PPAGE then scroll_by(page)
      when Curses::KEY_NPAGE then scroll_by(-page)
      else return false
      end
      true
    end

    # Asks ncurses for wheel events, but only where both directions decode.
    # Mouse reporting also stops the terminal from emulating the wheel with
    # arrow keys, and those arrows scroll both ways already on every build, so
    # on an old ncurses turning it on would lose more than it gains.
    def enable_mouse
      Curses.mousemask(WHEEL_UP | WHEEL_DOWN) if WHEEL_SUPPORTED
    rescue StandardError
      # A terminal without mouse support keeps the keyboard scroll keys.
    end

    # Wheel movement arrives as KEY_MOUSE followed by one getmouse event. Clicks
    # are outside the mask we ask for, so anything but wheel motion is ignored.
    def mouse_key(key)
      return false unless key == Curses::KEY_MOUSE

      event = Curses.getmouse
      delta = wheel_delta(event.bstate) if event
      scroll_by(delta) if delta
      true
    end

    # Rows a wheel event scrolls, or nil for any other mouse event.
    def wheel_delta(bstate)
      return WHEEL_STEP if (bstate & WHEEL_UP) != 0
      return -WHEEL_STEP if (bstate & WHEEL_DOWN) != 0

      nil
    end

    # Footer hint shown while the transcript is scrolled back.
    def scrolled_text
      hidden = @row_count - @top.to_i - @body_height.to_i
      text = "scrolled back · #{hidden} newer lines · Enter returns to the end"
      @busy ? "#{text}  ·  Ctrl-C cancel" : text
    end

    # Reverse incremental search over the transcript. Ctrl-F opens the prompt,
    # typing jumps to the nearest match at or above where the reader was, and
    # Enter walks to older matches and wraps around. Esc or Ctrl-C close the
    # prompt without touching the input line. Like scrolling it works while a
    # turn runs, because reading history does not touch the agent.
    def search_key(key)
      if key == SEARCH_KEY && !@search
        open_search
        return true
      end
      return false unless @search

      case key
      when 27, 3 then close_search # Esc and Ctrl-C close the prompt, not the app
      when 10, 13 then search_next
      when SEARCH_KEY then search_next unless @search.empty?
      when Curses::KEY_BACKSPACE, 8, 127
        @search = @search[0...-1]
        rerun_search
      else
        return true unless (text = next_char(@search_bytes, key))

        @search += text
        rerun_search
      end
      true
    end

    # Enter inside an open prompt: step to the next older match, wrapping to the
    # bottom of the transcript when the view is following the tail.
    def search_next
      search_jump((@top || search_row_count) - 1)
    end

    # Opens the prompt anchored at the top visible row, so the first match is
    # found at or above what the reader is looking at.
    def open_search
      @search = +''
      @search_anchor = [@top || (@row_count.to_i - @body_height.to_i), 0].max
      @search_found = nil
      @match_count = 0
    end

    # Closes the prompt and leaves the viewport where the search put it.
    def close_search
      @search = nil
      @search_found = nil
      @match_count = 0
    end

    # Re-runs the search from the anchor after the query changed. An empty query
    # only waits for more typing.
    def rerun_search
      @search_found = nil
      @match_count = 0
      return if @search.empty?

      search_jump(@search_anchor)
    end

    # Moves the viewport to the nearest match at or above `from`.
    def search_jump(from)
      index, matches = search_hits(from)
      @search_found = index
      @match_count = matches
      @top = index if index
      index
    end

    # The nearest matching row index at or above `from`, wrapping to the last
    # match when nothing above matches, plus the total number of matches.
    def search_hits(from)
      rows = search_rows
      needle = @search.downcase
      hits = rows.each_index.select { |index| rows[index].downcase.include?(needle) }
      return [nil, 0] if hits.empty?

      [hits.reverse.find { |index| index <= from } || hits.last, hits.length]
    end

    # Plain text of every transcript row in drawing order, so search and scroll
    # share row numbers. Layouts are cached per entry, so nothing is re-wrapped.
    def search_rows
      width = @body_width
      return [] unless width

      @entries.flat_map { |entry| ['', *body_rows(entry, width).map(&:text), ''] }
    end

    def search_row_count
      @row_count || search_rows.length
    end

    # Footer line for the open search prompt.
    def search_text
      return 'search: type to find text · Esc cancel' if @search.empty?

      found = @search_found.nil? ? 'no match' : "#{@match_count} match#{'es' unless @match_count == 1}"
      "#{found} · Enter older · Esc close"
    end

    # Wrapping is linear in text length, so re-laying out every turn on each
    # keystroke made long sessions feel sluggish. Rows are kept per entry and
    # reused until the text or the width changes; the text is copied because
    # streaming appends to the same String in place.
    def body_rows(entry, width)
      body = width - 4
      cached = entry[:layout]
      return cached[:rows] if cached && cached[:width] == body && cached[:text] == entry[:text]

      styled = if entry[:role] == :tool
                 Markdown.ruby_lines(entry[:text], body)
               else
                 Markdown.lines(entry[:text], body)
               end
      rows = styled.map { |row| row.indented('  ') }
      entry[:layout] = { width: body, text: entry[:text].dup, rows: rows }
      rows
    end

    def draw_footer(height, width)
      mode = @yolo ? '  ·  YOLO' : ''
      y = height - 3
      text = if @approval
               draw_plain_footer(y, width, "Run #{@approval.name}? [y] approve once  [n] deny", 3)
             elsif @search
               draw_plain_footer(y, width, search_text)
             elsif @top
               draw_plain_footer(y, width, scrolled_text)
             elsif @source_stale
               draw_plain_footer(y, width, 'code changed — /restart to apply')
             elsif @busy
               draw_busy_footer(y, width, mode)
             else
               draw_plain_footer(y, width, idle_footer_text(mode))
             end
      draw_stats(height, width, Text.width(text))
      put(height - 2, 0, '─' * width, width, 1)
    end

    # Draws a footer line in one colour and returns it unchanged, so the caller
    # can measure it to place the right-hand stats.
    def draw_plain_footer(y, width, text, color = 0)
      put(y, 1, text, width - 2, color)
      text
    end

    # Running turn's footer: the status word pulses through the colour ramp
    # while the hints after it stay in the default colour. Returns the full
    # line so the caller can measure it.
    def draw_busy_footer(y, width, mode)
      head = busy_text
      tail = "#{mode}  ·  Ctrl-C cancel"
      room = width - 2
      pair, attribute = pulse_style
      drawn = Text.slice(head, 0, room)
      put(y, 1, drawn, room, pair, attribute)
      used = Text.width(drawn)
      put(y, 1 + used, tail, room - used)
      head + tail
    end

    # Colour pair and attribute for the current pulse frame. Frames come from
    # the monotonic clock, so the animation keeps its own pace no matter how the
    # repaints are throttled; without colour pairs the status stays merely bold.
    def pulse_style
      frames = @pulse_pairs
      return [0, Curses::A_BOLD] if frames.nil? || frames.empty?

      [frames[(monotonic / PULSE_STEP).floor % frames.size], Curses::A_BOLD]
    end

    # Busy footer text: the current status plus how long the turn has run, so a
    # long tool call looks busy rather than stuck.
    def busy_text
      elapsed = live_elapsed
      elapsed ? "#{@status} · #{format_duration(elapsed)}" : @status
    end

    # Idle footer text. The scroll hint appears only once the transcript is
    # taller than the viewport, so a short session stays uncluttered.
    def idle_footer_text(mode)
      text = "#{@status}#{mode}  ·  Enter send  ·  /help  ·  Ctrl-C quit"
      text += '  ·  PgUp/PgDn scroll  ·  Ctrl-F find' if @row_count && @row_count > @body_height.to_i
      text
    end

    def draw_stats(height, width, left_width)
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

    # Sampling RSS forks `ps`, which measures ~90ms here and over a second when
    # the machine is loaded (exactly when tool runs keep it busy). On the draw
    # path that froze key handling for that long, so keys looked ignored.
    # Sample in the background and let the footer render the last sample.
    def sample_stats
      refresh_stats(force: true)
      # Unhandled event types are a no-op for drain_events yet still count as a
      # change, which repaints the footer while the UI is otherwise idle.
      @events << { type: :stats, payload: nil }
    end

    def start_stats_sampler
      @stats_thread = Thread.new do
        loop do
          begin
            sample_stats
          rescue StandardError
            # Stats are cosmetic; keep sampling rather than dying.
          end
          sleep STATS_INTERVAL
        end
      end
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

      @session.save(@agent.chat.messages, stamps: message_stamps)
      true
    rescue StandardError => e
      @entries << { role: :error, text: "session save failed: #{e.class}: #{e.message}" }
      false
    end

    # The timestamped user and assistant entries, in the order the screen
    # showed them, so the session can record when each turn was written.
    def message_stamps
      @entries.filter_map do |entry|
        next unless %i[user assistant].include?(entry[:role]) && entry[:at]

        { role: entry[:role], text: entry[:text], at: entry[:at] }
      end
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

    # Monotonic clock reading, so turn timings ignore wall-clock jumps.
    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Starts timing a user turn; the question's entry index is remembered so the
    # duration can be attached to whatever the turn ends up producing.
    def start_turn
      @turn_started_at = monotonic
      @turn_index = @entries.length - 1
      @tick_at = nil
    end

    # Stamps the turn that just finished with how long it took and returns the
    # seconds. The duration goes on the turn's last answer, or on the question
    # when the turn produced no text (cancelled, or tools only).
    def finish_turn
      started = @turn_started_at
      return unless started && @turn_index

      elapsed = monotonic - started
      @turn_started_at = nil
      @tick_at = nil
      entry = turn_answer || @entries[@turn_index]
      @turn_index = nil
      return unless entry

      entry[:elapsed] = elapsed
      entry.delete(:triples) # the label row grew, so relayout this entry
      elapsed
    end

    # The last assistant entry written after the turn started, if any.
    def turn_answer
      index = @entries.rindex { |entry| entry[:role] == :assistant }
      index && index >= @turn_index ? @entries[index] : nil
    end

    # Seconds the running turn has taken, or nil while nothing is running.
    def live_elapsed
      @turn_started_at ? monotonic - @turn_started_at : nil
    end

    # The footer clock only needs a few repaints a second, and the loop already
    # wakes every 50ms for the key read, so this throttles those wake-ups
    # instead of adding a timer thread.
    def live_tick?
      return false unless @turn_started_at

      now = monotonic
      return false if @tick_at && now - @tick_at < TICK_INTERVAL

      @tick_at = now
      true
    end

    # "0.8s" below ten seconds, "42s" below a minute, "2m 05s" beyond that.
    def format_duration(seconds)
      if seconds < 10
        format('%.1fs', seconds)
      elsif seconds < 60
        format('%ds', seconds)
      else
        format('%dm %02ds', seconds / 60, seconds % 60)
      end
    end

    def draw_input(height, width)
      text = @search || @input
      cursor = @search ? text.length : @cursor
      prompt = @search ? 'find> ' : '> '
      room = width - prompt.length - 1
      offset = [Text.width(text[0...cursor]) - room + 1, 0].max
      put(height - 1, 0, prompt, width, 1, Curses::A_BOLD)
      put(height - 1, prompt.length, Text.slice(text, offset, room), room, 0)
      Curses.curs_set(@busy && !@search ? 0 : 1)
      column = prompt.length + Text.width(text[0...cursor]) - offset
      @window.setpos(height - 1, [column, width - 1].min)
    end

    # Draws one wrapped Row: segments with their own style take the style's
    # colour, unstyled ones fall back to the row colour (used by the labels).
    def put_row(y, x, row, max_width, color = 0, attribute = 0)
      used = 0
      row.segments.each do |text, style|
        room = max_width - used
        break if room <= 0

        seg_color, seg_attribute = style ? style_attributes(style) : [color, attribute]
        chunk = Text.slice(text, 0, room)
        put(y, x + used, chunk, room, seg_color, seg_attribute)
        used += Text.width(chunk)
      end
    end

    # Colour and attribute for a segment style. Token colours need pairs a
    # monochrome or pair-starved terminal may not have: those read as code.
    def style_attributes(style)
      return STYLES[:code] if !@ruby_pairs && RUBY_PAIRS.key?(style)

      STYLES.fetch(style, [0, 0])
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
