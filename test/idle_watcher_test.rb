# frozen_string_literal: true

require_relative 'test_helper'

class IdleWatcherTest < Minitest::Test
  # Deterministic clock so tests don't depend on real sleeps.
  class FakeClock
    def initialize
      @t = 0.0
    end

    def call = @t
    def advance(seconds) = @t += seconds
  end

  def setup
    @clock = FakeClock.new
    @fired = []
    @watcher = Rubycog::IdleWatcher.new(
      idle_threshold: 60, cooldown: 120, tick: 0.01,
      clock: @clock, on_fire: ->(action) { @fired << action }
    )
  end

  def teardown
    @watcher.stop
  end

  def test_does_not_fire_before_threshold
    @watcher.start
    @clock.advance(30)
    @watcher.send(:fire_if_due)
    assert_empty @fired
  end

  def test_fires_evolve_first_after_threshold
    @watcher.start
    @clock.advance(61)
    @watcher.send(:fire_if_due)
    assert_equal [:evolve], @fired
  end

  def test_alternates_evolve_and_introspect
    @watcher.start
    @clock.advance(61)
    @watcher.send(:fire_if_due)
    @clock.advance(200)  # past cooldown
    @watcher.send(:fire_if_due)
    @clock.advance(200)
    @watcher.send(:fire_if_due)
    assert_equal %i[evolve introspect evolve], @fired
  end

  def test_cooldown_blocks_immediate_refire
    @watcher.start
    @clock.advance(61)
    @watcher.send(:fire_if_due)
    # 1 second later, well under cooldown
    @clock.advance(1)
    @watcher.send(:fire_if_due)
    assert_equal 1, @fired.size
  end

  def test_cooldown_allows_after_period
    @watcher.start
    @clock.advance(61)
    @watcher.send(:fire_if_due)
    @clock.advance(121)
    @watcher.send(:fire_if_due)
    assert_equal 2, @fired.size
  end

  def test_notify_activity_resets_idle_timer
    @watcher.start
    @clock.advance(50)
    @watcher.notify_activity
    @clock.advance(30)  # would have fired without the reset
    @watcher.send(:fire_if_due)
    assert_empty @fired
  end

  def test_notify_activity_clears_cooldown
    @watcher.start
    @clock.advance(61)
    @watcher.send(:fire_if_due)
    assert_equal 1, @fired.size
    @watcher.notify_activity
    # Should now need a full idle_threshold again, but cooldown is gone.
    @clock.advance(61)
    @watcher.send(:fire_if_due)
    assert_equal 2, @fired.size
  end

  def test_idle_for_reports_elapsed
    @watcher.start
    @clock.advance(25)
    assert_in_delta 25.0, @watcher.idle_for, 0.001
  end

  def test_cooldown_remaining
    @watcher.start
    @clock.advance(61)
    @watcher.send(:fire_if_due)
    @clock.advance(30)
    assert_in_delta 90.0, @watcher.cooldown_remaining, 0.001
  end

  def test_time_to_fire
    @watcher.start
    @clock.advance(20)
    assert_in_delta 40.0, @watcher.time_to_fire, 0.001
  end

  def test_time_to_fire_when_stopped_is_infinite
    assert_equal Float::INFINITY, @watcher.time_to_fire
  end

  def test_next_action_reflects_alternation
    @watcher.start
    assert_equal :evolve, @watcher.next_action
    @clock.advance(61)
    @watcher.send(:fire_if_due)
    assert_equal :introspect, @watcher.next_action
  end

  def test_start_action_can_be_overridden
    w = Rubycog::IdleWatcher.new(clock: @clock, start_action: :introspect,
                                  on_fire: ->(a) { @fired << a },
                                  idle_threshold: 1, cooldown: 1000, tick: 0.01)
    w.start
    @clock.advance(2)
    w.send(:fire_if_due)
    assert_equal [:introspect], @fired
    w.stop
  end

  def test_stop_prevents_further_fires
    @watcher.start
    @watcher.stop
    @clock.advance(100)
    @watcher.send(:fire_if_due)
    assert_empty @fired
  end

  def test_running_flag
    refute @watcher.running?
    @watcher.start
    assert @watcher.running?
    @watcher.stop
    refute @watcher.running?
  end

  def test_start_is_idempotent
    @watcher.start
    @watcher.start
    assert @watcher.running?
    @watcher.stop
  end

  def test_stop_is_idempotent
    @watcher.stop
    @watcher.stop
    refute @watcher.running?
  end

  def test_on_fire_exception_does_not_kill_watcher
    bad = Rubycog::IdleWatcher.new(clock: @clock,
                                    on_fire: ->(_a) { raise 'boom' },
                                    idle_threshold: 1, cooldown: 1, tick: 0.01)
    bad.start
    @clock.advance(2)
    bad.send(:fire_if_due)  # should not raise
    bad.stop
  end

  def test_background_thread_actually_fires
    # Use a real clock this once to verify the thread loop works end-to-end.
    real_fired = Queue.new
    w = Rubycog::IdleWatcher.new(idle_threshold: 0.1, cooldown: 100, tick: 0.02,
                                  on_fire: ->(a) { real_fired << a })
    w.start
    action = real_fired.pop  # blocks until the watcher fires
    assert_equal :evolve, action
    w.stop
  end
end
