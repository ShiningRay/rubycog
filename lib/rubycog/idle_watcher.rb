# frozen_string_literal: true

module Rubycog
  # Background thread that watches for user inactivity and periodically asks
  # the host (TUI) to run an evolution or introspection pass. The watcher is
  # passive: it never invokes tools or writes files itself, it just calls the
  # injected block with a symbol (:evolve or :introspect) on the watcher
  # thread. The host is responsible for actually driving the agent loop.
  #
  # Lifecycle:
  #   - `start` spawns the thread. Safe to call twice.
  #   - `stop` terminates the thread and waits for it to join.
  #   - `notify_activity` resets the idle timer. Call on every user input.
  #
  # Timing:
  #   - Idle trigger: fire when `idle_for >= idle_threshold` seconds.
  #   - Cooldown: after firing, suppress further fires for `cooldown` seconds
  #     even if the user stays idle. `notify_activity` clears the cooldown.
  #   - Tick: the thread wakes every `tick` seconds to re-check.
  #
  # Alternation: the watcher alternates between :evolve and :introspect so a
  # long idle period produces a mix of both rather than N of one kind.
  class IdleWatcher
    TICK = 5
    IDLE_THRESHOLD = 15 * 60
    COOLDOWN = 60 * 60
    ACTIONS = %i[evolve introspect].freeze

    attr_reader :idle_threshold, :cooldown, :tick

    # clock:     -> Float, monotonic seconds (Process.clock_gettime by default)
    # on_fire:   (Symbol) -> void, called with :evolve or :introspect
    def initialize(idle_threshold: IDLE_THRESHOLD, cooldown: COOLDOWN, tick: TICK,
                   clock: nil, on_fire: nil, start_action: :evolve)
      @idle_threshold = idle_threshold
      @cooldown = cooldown
      @tick = tick
      @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @on_fire = on_fire
      @next_action = ACTIONS.include?(start_action) ? start_action : :evolve
      @mutex = Mutex.new
      @last_activity = now
      @last_fire = nil
      @thread = nil
      @running = false
    end

    def running?
      @mutex.synchronize { @running }
    end

    def start
      @mutex.synchronize do
        return self if @running

        @running = true
        @last_activity = now
        @thread = Thread.new { loop_tick }
        @thread.name = 'rubycog-idle-watcher' if @thread.respond_to?(:name=)
      end
      self
    end

    def stop
      thread = nil
      @mutex.synchronize do
        return self unless @running

        @running = false
        thread = @thread
        @thread = nil
      end
      thread&.wakeup rescue nil
      thread&.join(2)
      self
    end

    # Record user activity. Resets the idle timer and clears any cooldown so
    # the next idle period starts from zero.
    def notify_activity
      @mutex.synchronize do
        @last_activity = now
        @last_fire = nil
      end
      self
    end

    # Seconds since last user activity (or watcher start, whichever is later).
    def idle_for
      @mutex.synchronize { now - @last_activity }
    end

    # Seconds remaining before the watcher is allowed to fire again. Returns
    # 0 when firing is allowed. Takes cooldown into account but NOT idle
    # threshold (use time_to_fire for the full picture).
    def cooldown_remaining
      @mutex.synchronize do
        return 0 unless @last_fire

        elapsed = now - @last_fire
        remaining = @cooldown - elapsed
        remaining.positive? ? remaining : 0
      end
    end

    # Seconds until the watcher will next fire, assuming no user activity.
    # 0 means it would fire on the next tick. Float::INFINITY when stopped.
    def time_to_fire
      return Float::INFINITY unless running?

      cd = cooldown_remaining
      return cd if cd.positive?

      remaining = @idle_threshold - idle_for
      remaining.positive? ? remaining : 0
    end

    # Next action the watcher will emit. Useful for status displays.
    def next_action
      @mutex.synchronize { @next_action }
    end

    private

    def now
      @clock.call
    end

    def loop_tick
      while @mutex.synchronize { @running }
        sleep @tick
        break unless @mutex.synchronize { @running }

        fire_if_due
      end
    rescue StandardError
      # The watcher thread must never take down the host. Swallow and exit;
      # the host can start a new watcher if it notices.
      nil
    end

    def fire_if_due
      action = nil
      @mutex.synchronize do
        return unless @running
        return if @last_fire && (now - @last_fire) < @cooldown
        return if (now - @last_activity) < @idle_threshold

        @last_fire = now
        # Treat the fire as activity so the idle clock restarts.
        @last_activity = now
        action = @next_action
        @next_action = action == :evolve ? :introspect : :evolve
      end
      return unless action && @on_fire

      begin
        @on_fire.call(action)
      rescue StandardError
        # Host errors must not kill the watcher thread.
        nil
      end
    end
  end
end
