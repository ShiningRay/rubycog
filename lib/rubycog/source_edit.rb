# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'rbconfig'
require 'time'
require 'tmpdir'

module Rubycog
  # Reads and edits RubyCog source files with backups, Ruby syntax checks and a
  # textual diff. It never decides whether an edit is allowed: callers resolve
  # and validate the path through SourcePath first.
  module SourceEdit
    MAX_LINES = 200
    MAX_BYTES = 20_000
    MAX_FILE_BYTES = 200_000

    module_function

    def read(full, relative, start_line: nil, end_line: nil)
      raise ArgumentError, "file is too large: #{relative}" if File.size(full) > MAX_FILE_BYTES

      lines = File.readlines(full, chomp: true)
      first = [[start_line.to_i - 1, 0].max, lines.length].min
      last = if end_line
               [[end_line.to_i, lines.length].min, first].max
             else
               [first + MAX_LINES, lines.length].min
             end

      body = lines[first...last].to_a.each_with_index.map do |line, index|
        format('%4d | %s', first + index + 1, line)
      end.join("\n")
      body = body[0, MAX_BYTES].to_s
      "# #{relative} (lines #{first + 1}-#{last})\n#{body}"
    end

    def plan(full, relative, old_string, new_string)
      original = File.exist?(full) ? File.read(full) : ''
      replacement = new_string.to_s

      updated = if old_string.to_s.empty?
                  raise ArgumentError, 'old_string is required when the file exists' if File.exist?(full)
                  unless relative.start_with?('test/', 'docs/')
                    raise ArgumentError, 'new files are only allowed under test/ or docs/'
                  end

                  replacement
                else
                  matches = original.scan(old_string).length
                  unless matches == 1
                    raise ArgumentError, "old_string must match exactly once (found #{matches})"
                  end

                  original.sub(old_string, replacement)
                end

      raise ArgumentError, 'edit does not change the file' if updated == original

      {
        original: original,
        updated: updated,
        diff: unified_diff(original, updated, relative)
      }
    end

    def apply(full, relative, old_string, new_string, reason:, backup_root: File.join(Rubycog.root, '.rubycog', 'backups'))
      prepared = begin
        plan(full, relative, old_string, new_string)
      rescue ArgumentError => e
        return { ok: false, stage: 'plan', error: e.message, reason: reason }
      end
      backup = backup_file(full, relative, backup_root)
      mode = File.exist?(full) ? File.stat(full).mode & 0o777 : 0o644
      tmp = "#{full}.#{Process.pid}.tmp"

      File.write(tmp, prepared[:updated])
      File.chmod(mode, tmp)
      File.rename(tmp, full)

      syntax = syntax_check(full)
      unless syntax[:ok]
        restore(full, backup)
        return {
          ok: false, stage: 'syntax', error: syntax[:output],
          diff: prepared[:diff], backup: backup, reason: reason
        }
      end

      {
        ok: true, stage: 'done', diff: prepared[:diff],
        backup: backup, reason: reason, syntax: syntax[:output]
      }
    rescue StandardError => e
      restore(full, backup) if backup
      { ok: false, stage: 'write', error: "#{e.class}: #{e.message}", reason: reason }
    ensure
      FileUtils.rm_f(tmp) if defined?(tmp) && tmp
    end

    # Checks that Ruby files still parse. Other whitelisted files (Markdown,
    # README, Gemfile) are not Ruby, so the check is skipped rather than failed.
    def syntax_check(full)
      return { ok: true, output: 'no syntax check (not a Ruby file)' } unless ruby_file?(full)

      output, error, status = Open3.capture3(RbConfig.ruby, '-c', full)
      { ok: status.success?, output: [output, error].reject(&:empty?).join("\n") }
    rescue SystemCallError => e
      { ok: false, output: "#{e.class}: #{e.message}" }
    end

    # True when the path is Ruby source that ruby -c can parse.
    def ruby_file?(full)
      File.extname(full) == '.rb'
    end

    def backup_file(full, relative, backup_root)
      return unless File.exist?(full)

      stamp = Time.now.utc.strftime('%Y%m%dT%H%M%S%6NZ')
      backup = File.join(backup_root, "#{stamp}-#{Process.pid}", relative)
      FileUtils.mkdir_p(File.dirname(backup))
      FileUtils.cp(full, backup)
      backup
    end

    def restore(full, backup)
      if backup && File.exist?(backup)
        FileUtils.cp(backup, full)
      else
        FileUtils.rm_f(full)
      end
    end

    def unified_diff(before, after, relative)
      external = external_diff(before, after, relative)
      return external if external

      fallback_diff(before, after, relative)
    end

    # Runs the platform `diff` when it exists; nil means the caller has to
    # render the diff itself, which is the normal case on Windows.
    def external_diff(before, after, relative)
      Dir.mktmpdir('rubycog-diff') do |dir|
        old_path = File.join(dir, 'before')
        new_path = File.join(dir, 'after')
        File.write(old_path, before)
        File.write(new_path, after)
        output, = Open3.capture2e(
          'diff', '-u', '-L', "a/#{relative}", '-L', "b/#{relative}", old_path, new_path
        )
        return output unless output.strip.empty?
      end
      nil
    rescue SystemCallError
      nil
    end

    # Renders a unified diff without an external program. Common prefix and
    # suffix lines are dropped so only the changed region is shown; that is a
    # valid hunk and enough for the audit trail and the self-iteration record.
    def fallback_diff(before, after, relative)
      old_lines = before.to_s.lines
      new_lines = after.to_s.lines
      prefix = common_prefix(old_lines, new_lines)
      suffix = common_suffix(old_lines, new_lines, prefix)
      removed = old_lines[prefix...(old_lines.length - suffix)] || []
      added = new_lines[prefix...(new_lines.length - suffix)] || []

      header = "--- a/#{relative}\n+++ b/#{relative}\n"
      return header if removed.empty? && added.empty?

      hunk = "@@ -#{prefix + 1},#{removed.length} +#{prefix + 1},#{added.length} @@\n"
      body = removed.map { |line| "-#{line}" }.join + added.map { |line| "+#{line}" }.join
      "#{header}#{hunk}#{body}"
    end

    def common_prefix(old_lines, new_lines)
      limit = [old_lines.length, new_lines.length].min
      index = 0
      index += 1 while index < limit && old_lines[index] == new_lines[index]
      index
    end

    def common_suffix(old_lines, new_lines, prefix)
      limit = [old_lines.length, new_lines.length].min - prefix
      count = 0
      count += 1 while count < limit && old_lines[-1 - count] == new_lines[-1 - count]
      count
    end
  end
end
