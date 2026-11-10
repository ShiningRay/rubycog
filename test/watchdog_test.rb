# frozen_string_literal: true

# The watchdog is deliberately stdlib-only so it can supervise a process whose
# bundle is broken. These tests therefore require minitest directly rather than
# test_helper.rb, which loads lib/rubycog and its gems: the watchdog suite must
# stay runnable when the bundle itself is the thing that needs repairing.
require 'json'
require 'minitest/autorun'
require 'rbconfig'
require 'tmpdir'

class WatchdogTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  SCRIPT = File.join(ROOT, 'scripts', 'watchdog.rb')
  RUBY = RbConfig.ruby

  # Child processes must not inherit bundler's preload: the watchdog is meant to
  # run without it, and the fake children only need the Ruby stdlib.
  CLEAN_ENV = {
    'RUBYOPT' => nil,
    'BUNDLER_SETUP' => nil,
    'BUNDLE_GEMFILE' => nil
  }.freeze

  def setup
    @sequence = 0
  end

  def test_crash_writes_meta_json_and_readme
    in_tmpdir do |dir|
      _out, err, status = run_watchdog(dir, '--once', '--', RUBY, '-e', 'STDERR.puts "boom"; exit 1')

      assert_equal 1, status.exitstatus, err
      crashes = crash_dirs(dir)
      assert_equal 1, crashes.length, 'expected exactly one crash bundle'
      crash = crashes.first

      meta = JSON.parse(File.read(File.join(crash, 'meta.json')))
      assert_equal 1, meta['exit_code']
      assert_equal false, meta['signaled']
      assert_operator meta['uptime_seconds'], :>=, 0
      assert_equal [RUBY, '-e', 'STDERR.puts "boom"; exit 1'], meta['command']
      assert_equal File.expand_path(ROOT), File.expand_path(meta['cwd'])
      refute_nil meta['ruby_version']
      assert_includes meta['log_tail'], 'boom'

      readme = File.read(File.join(crash, 'README.md'))
      assert_includes readme, 'Exit code: 1'
      assert_includes readme, 'Command line:'
      assert_includes readme, 'Working directory:'
      assert_includes readme, 'Git HEAD:'
      assert_includes readme, 'git status --porcelain'
      assert_includes readme, 'boom'
      assert_includes readme, '```text'
      assert_equal 'stopped', status_json(dir)['state']
      assert_equal 1, status_json(dir)['last_exit']
    end
  end

  def test_clean_exit_records_no_crash
    in_tmpdir do |dir|
      _out, err, status = run_watchdog(dir, '--once', '--', RUBY, '-e', 'puts "ok"')

      assert_equal 0, status.exitstatus, err
      assert_empty crash_dirs(dir)
      assert_equal 'stopped', status_json(dir)['state']
      assert_equal 0, status_json(dir)['last_exit']

      logs = Dir.glob(File.join(dir, 'run-*.log'))
      assert_equal 1, logs.length
      assert_includes File.read(logs.first), 'ok'
    end
  end

  def test_repair_gets_the_report_path_and_a_successful_run_restarts
    in_tmpdir do |dir|
      marker = File.join(dir, 'marker')
      repaired = File.join(dir, 'repair-arg.txt')
      repair_script = File.join(dir, 'repair.rb')
      File.write(repair_script, <<~RUBY)
        File.write(ENV.fetch('REPAIR_OUT'), ARGV[0].to_s)
        File.write(ENV.fetch('MARKER'), 'fixed')
      RUBY
      child = 'exit(File.exist?(ENV.fetch("MARKER")) ? 0 : 1)'
      repair_command = "#{double_quote(RUBY)} #{double_quote(repair_script)} %{report}"

      _out, err, status = run_watchdog(
        dir, '--repair', repair_command, '--backoff', '0',
        '--', RUBY, '-e', child,
        env: { 'MARKER' => marker, 'REPAIR_OUT' => repaired }
      )

      assert_equal 0, status.exitstatus, err
      report = File.read(repaired)
      assert_equal 'README.md', File.basename(report)
      assert File.exist?(report), "repair received a missing report path: #{report.inspect}"
      assert_includes File.read(report), 'Exit code: 1'

      crashes = crash_dirs(dir)
      assert_equal 1, crashes.length
      repair_log = File.read(File.join(crashes.first, 'repair.log'))
      assert_includes repair_log, 'repair finished'
      assert_includes repair_log, 'README.md'
      assert_equal 1, status_json(dir)['restarts']
      assert_equal 0, status_json(dir)['last_exit']
    end
  end

  def test_restart_budget_exhaustion_exits_two
    in_tmpdir do |dir|
      _out, err, status = run_watchdog(dir, '--backoff', '0', '--max-restarts', '2',
                                       '--', RUBY, '-e', 'exit 1')

      assert_equal 2, status.exitstatus, err
      assert_equal 3, crash_dirs(dir).length, 'expected the initial run plus two restarts'
      assert_includes err, 'restart budget exhausted'
      final = status_json(dir)
      assert_equal 'stopped', final['state']
      assert_equal 2, final['restarts']
      assert_equal 1, final['last_exit']
    end
  end

  def test_once_runs_the_child_exactly_once
    in_tmpdir do |dir|
      counter = File.join(dir, 'count.txt')
      code = 'File.open(ENV.fetch("COUNTER"), "a") { |file| file.puts "run" }; exit 0'

      _out, err, status = run_watchdog(dir, '--once', '--', RUBY, '-e', code,
                                       env: { 'COUNTER' => counter })

      assert_equal 0, status.exitstatus, err
      assert_equal 1, File.readlines(counter).length
      assert_equal 1, Dir.glob(File.join(dir, 'run-*.log')).length
      assert_empty crash_dirs(dir)
    end
  end

  def test_stop_file_kills_the_child_without_recording_a_crash
    in_tmpdir do |dir|
      stop_file = File.join(dir, 'stop')
      marker = File.join(dir, 'child-started')
      child = "File.write(ENV.fetch('CHILD_STARTED'), '1'); sleep 30"
      @sequence += 1
      out_path = File.join(dir, "supervisor-#{@sequence}.out")
      err_path = File.join(dir, "supervisor-#{@sequence}.err")
      pid = Process.spawn(CLEAN_ENV.merge('CHILD_STARTED' => marker), RUBY, SCRIPT,
                          '--log-dir', dir, '--stop-file', stop_file, '--', RUBY, '-e', child,
                          chdir: ROOT, out: out_path, err: err_path)
      begin
        running = wait_for_running(dir, timeout: 15)
        child_pid = running['pid']
        assert child_pid, 'status.json must name the child pid while running'
        wait_until(5) { File.exist?(marker) }
        assert File.exist?(marker), 'child never started'

        File.write(stop_file, 'stop')
        supervisor_status = wait_for(pid, 15)
        assert_equal 0, supervisor_status.exitstatus, File.read(err_path)
        refute process_alive?(child_pid), 'the child must be killed on shutdown'

        final = status_json(dir)
        assert_equal 'stopped', final['state']
        assert_nil final['pid']
        assert_empty crash_dirs(dir)
      ensure
        kill(pid) if process_alive?(pid)
      end
    end
  end

  def test_missing_command_is_a_configuration_error
    in_tmpdir do |dir|
      _out, err, status = run_watchdog(dir, '--once')

      assert_equal 1, status.exitstatus
      assert_includes err, 'missing command'
      refute File.exist?(File.join(dir, 'status.json'))
    end
  end

  private

  def in_tmpdir
    Dir.mktmpdir('rubycog-watchdog') { |dir| yield dir }
  end

  def run_watchdog(dir, *args, env: {}, timeout: 30)
    @sequence += 1
    out_path = File.join(dir, "supervisor-#{@sequence}.out")
    err_path = File.join(dir, "supervisor-#{@sequence}.err")
    pid = Process.spawn(CLEAN_ENV.merge(env), RUBY, SCRIPT, '--log-dir', dir, *args,
                        chdir: ROOT, out: out_path, err: err_path)
    status = wait_for(pid, timeout)
    [File.read(out_path), File.read(err_path), status]
  end

  def wait_for(pid, timeout)
    deadline = monotonic + timeout
    loop do
      _waited_pid, status = Process.wait2(pid, Process::WNOHANG)
      return status if status

      if monotonic > deadline
        kill(pid)
        flunk "process #{pid} did not exit within #{timeout}s"
      end
      sleep 0.02
    end
  end

  def kill(pid)
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

  def wait_for_running(dir, timeout:)
    path = File.join(dir, 'status.json')
    deadline = monotonic + timeout
    loop do
      if File.exist?(path)
        data = begin
          JSON.parse(File.read(path))
        rescue JSON::ParserError
          nil
        end
        return data if data && data['state'] == 'running' && data['pid']
      end
      flunk 'status.json never reported a running child' if monotonic > deadline
      sleep 0.02
    end
  end

  def wait_until(timeout)
    deadline = monotonic + timeout
    until yield
      flunk "condition was not met within #{timeout}s" if monotonic > deadline
      sleep 0.02
    end
  end

  def status_json(dir)
    JSON.parse(File.read(File.join(dir, 'status.json')))
  end

  def crash_dirs(dir)
    Dir.glob(File.join(File.expand_path(dir), 'crashes', '*')).select { |path| File.directory?(path) }
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH, Errno::EINVAL
    false
  rescue Errno::EPERM
    true
  end

  def double_quote(value)
    "\"#{value.gsub('"', '""')}\""
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
