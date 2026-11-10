# frozen_string_literal: true

# Turns a crash report into an AI repair run.
#
# The watchdog writes a directory per crash (README.md, meta.json,
# log_tail.txt). This script reads it, asks `dsh headless` to diagnose and fix
# the checkout, and streams the repair transcript to stdout so the watchdog's
# repair.log keeps a full record. It is the `--repair` command of
# scripts/watchdog.rb:
#
#   ruby scripts/watchdog.rb --repair "ruby scripts/dsh_repair.rb --report %{report}" \
#     -- ruby bin/rubycog --headless --daemon
#
# Stdlib only, so it runs even when the bundle is broken by the crash.

require 'open3'
require 'optparse'
require 'rbconfig'
require 'timeout'
require 'yaml'

module DshRepair
  DEFAULT_TIMEOUT = 1200
  MAX_REPORT_BYTES = 60_000

  module_function

  def main(argv)
    options = parse(argv)
    report = read_report(options[:report])
    prompt = build_prompt(report, options)
    return 0 if options[:dry_run] && print_prompt(prompt)

    run_dsh(prompt, options)
  end

  def parse(argv)
    options = {
      repo: File.expand_path('..', __dir__),
      dsh: ENV['DSH_BIN'] || 'dsh',
      timeout: DEFAULT_TIMEOUT,
      credentials: File.expand_path('~/.dsh/.credentials.yaml'),
      extra: nil,
      dry_run: false
    }
    OptionParser.new do |opts|
      opts.banner = 'Usage: ruby scripts/dsh_repair.rb --report PATH [options]'
      opts.on('--report PATH', 'Crash report directory or README.md path') { |v| options[:report] = v }
      opts.on('--repo DIR', 'Checkout the agent may edit') { |v| options[:repo] = File.expand_path(v) }
      opts.on('--dsh CMD', 'dsh executable (default: dsh, or DSH_BIN)') { |v| options[:dsh] = v }
      opts.on('--timeout SECONDS', Float, "Kill the repair after this long (default #{DEFAULT_TIMEOUT})") do |v|
        options[:timeout] = v
      end
      opts.on('--credentials PATH', 'DSH credential store to read provider keys from') do |v|
        options[:credentials] = File.expand_path(v)
      end
      opts.on('--prompt-extra TEXT', 'Appended to the repair prompt') { |v| options[:extra] = v }
      opts.on('--dry-run', 'Print the prompt instead of calling dsh') { options[:dry_run] = true }
      opts.on('-h', '--help', 'Show this help') do
        puts opts
        exit 0
      end
    end.parse!(argv)
    abort 'dsh_repair: --report is required' unless options[:report]
    options[:report] = File.expand_path(options[:report])
    abort "dsh_repair: no crash report at #{options[:report]}" unless File.exist?(options[:report])
    options
  end

  # The watchdog hands over README.md (human readable) or the directory itself.
  def read_report(path)
    dir = File.directory?(path) ? path : File.dirname(path)
    {
      dir: dir,
      readme: read_text(File.join(dir, 'README.md')),
      meta: read_text(File.join(dir, 'meta.json')),
      log_tail: read_text(File.join(dir, 'log_tail.txt'))
    }
  end

  def read_text(path)
    return '' unless File.file?(path)

    text = File.read(path, encoding: 'UTF-8', invalid: :replace, undef: :replace)
    text.length > MAX_REPORT_BYTES ? "#{text[0, MAX_REPORT_BYTES]}\n… (truncated)" : text
  end

  def build_prompt(report, options)
    <<~PROMPT
      You are repairing a Ruby project at #{options[:repo]}.
      A supervised run crashed and the watchdog captured a crash report in
      #{report[:dir]}. Diagnose the root cause, fix it with the smallest change
      that keeps the existing tests green, and prove the fix.

      Rules:
      - Read the report first: README.md, meta.json and log_tail.txt are below.
      - Reproduce the failure with the recorded command before changing code.
      - Prefer fixing lib/, bin/ or scripts/ over deleting or weakening tests.
      - Run `bundle exec rake test` (or the recorded command) after the fix.
      - Never print or edit secrets; .env and .dsh credentials are off limits.
      - If the crash is environmental (missing compiler, unreachable gateway),
        stop and report that instead of faking a code fix.
      - Finish with a short summary: root cause, files changed, test result.

      === crash README.md ===
      #{report[:readme]}

      === crash meta.json ===
      #{report[:meta]}

      === last log lines ===
      #{report[:log_tail]}
    PROMPT
  end

  def print_prompt(prompt)
    puts prompt
    true
  end

  # The dsh CLI reads provider keys from the environment, while the desktop app
  # keeps them in the credentials store, so they are copied across explicitly.
  def credentials_env(path)
    return {} unless File.file?(path)

    refs = YAML.load_file(path).fetch('refs', {}) || {}
    refs.each_with_object({}) do |(name, value), env|
      next unless name.to_s.end_with?('_API_KEY')
      next if value.to_s.strip.empty?
      next unless ENV[name].to_s.strip.empty? # an exported key wins

      env[name] = value
    end
  rescue StandardError => e
    warn "dsh_repair: could not read credentials: #{e.class}: #{e.message}"
    {}
  end

  def run_dsh(prompt, options)
    env = credentials_env(options[:credentials])
    command = [options[:dsh], '--profile', 'headless', '--approval-policy', 'never', '-']
    started = Time.now
    status = nil
    log("repair: #{options[:dsh]} headless in #{options[:repo]} (timeout #{options[:timeout].round}s)")

    Open3.popen3(env, *command, chdir: options[:repo]) do |stdin, stdout, stderr, wait|
      writer = Thread.new do
        stdin.write(prompt)
        stdin.close
      rescue Errno::EPIPE
        nil
      end
      readers = [Thread.new { pump(stdout) }, Thread.new { pump(stderr) }]
      status = wait_with_timeout(wait, options[:timeout])
      [writer, *readers].each { |thread| thread.join(5) }
    end

    log("repair: finished in #{(Time.now - started).round(1)}s, exit=#{status&.exitstatus || 'timeout'}")
    status&.exitstatus || 1
  rescue SystemCallError => e
    warn "dsh_repair: cannot run #{options[:dsh]}: #{e.class}: #{e.message}"
    1
  end

  def pump(stream)
    stream.each_line { |line| $stdout.write(line) }
  rescue IOError
    nil
  end

  def wait_with_timeout(wait, seconds)
    Timeout.timeout(seconds) { wait.value }
  rescue Timeout::Error
    warn "dsh_repair: repair timed out after #{seconds.round}s; killing it"
    Process.kill('KILL', wait.pid)
    wait.value
  end

  def log(message)
    $stdout.puts("[#{Time.now.utc.strftime('%H:%M:%SZ')}] #{message}")
    $stdout.flush
  end
end

exit DshRepair.main(ARGV) if $PROGRAM_NAME == __FILE__
