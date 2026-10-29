# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'time'

module Rubycog
  # Append-only audit log for self-edits and test runs. The file lives under
  # .rubycog/ next to the project and is never committed.
  class SelfIteration
    DEFAULT_PATH = File.join(Rubycog.root, '.rubycog', 'self_iteration.json')
    MAX_RECORDS = 50
    MAX_TEXT = 4_000

    attr_reader :path, :records

    def initialize(path: DEFAULT_PATH)
      @path = path
      @records = read
    end

    def record(kind:, **data)
      entry = { 'at' => Time.now.utc.iso8601, 'kind' => kind.to_s }
      data.each { |key, value| entry[key.to_s] = value }
      @records = (@records + [entry]).last(MAX_RECORDS)
      write
      entry
    end

    def record_edit(path:, reason:, ok:, diff: nil, backup: nil, error: nil)
      record(kind: 'edit', path: path, reason: reason, ok: ok,
             diff: truncate(diff), backup: backup, error: truncate(error))
    end

    def record_test(paths:, ok:, exit_status:, output: nil)
      record(kind: 'test', paths: Array(paths), ok: ok,
             exit_status: exit_status, output: truncate(output))
    end

    def summary
      return 'no self-iteration records' if records.empty?

      last_edit = records.reverse.find { |entry| entry['kind'] == 'edit' }
      last_test = records.reverse.find { |entry| entry['kind'] == 'test' }
      parts = []
      if last_edit
        state = last_edit['ok'] ? 'ok' : 'failed'
        parts << "last edit #{last_edit['path']} (#{state})"
      end
      if last_test
        state = last_test['ok'] ? 'passed' : 'failed'
        parts << "last test #{state}"
      end
      parts.join(' · ')
    end

    def recent(limit = 5)
      records.last(limit)
    end

    def to_text(limit = 5)
      return "self-iteration: #{path}\n(no records)" if records.empty?

      lines = ["self-iteration: #{path}"]
      recent(limit).each do |entry|
        label = entry['kind'] == 'edit' ? entry['path'] : Array(entry['paths']).join(', ')
        state = entry['ok'] ? 'ok' : 'failed'
        reason = entry['reason'] ? " — #{entry['reason']}" : ''
        lines << "#{entry['at']} #{entry['kind']} #{label} (#{state})#{reason}"
      end
      lines.join("\n")
    end

    private

    def read
      return [] unless path && File.exist?(path)

      data = JSON.parse(File.read(path))
      entries = data.is_a?(Hash) ? data['records'] : data
      Array(entries).select { |entry| entry.is_a?(Hash) && entry['kind'] }.last(MAX_RECORDS)
    rescue JSON::ParserError, SystemCallError
      []
    end

    def write
      return unless path

      FileUtils.mkdir_p(File.dirname(path))
      payload = { 'version' => 1, 'updated_at' => Time.now.utc.iso8601, 'records' => records }
      tmp = "#{path}.#{Process.pid}.tmp"
      File.write(tmp, JSON.pretty_generate(payload))
      File.chmod(0o600, tmp)
      File.rename(tmp, path)
    rescue SystemCallError
      nil
    end

    def truncate(text)
      return nil if text.nil?

      value = text.to_s
      value.length > MAX_TEXT ? "#{value[0, MAX_TEXT]}\n… (truncated)" : value
    end
  end
end
