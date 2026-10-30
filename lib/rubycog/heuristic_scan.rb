# frozen_string_literal: true

module Rubycog
  # Cheap structural smells that don't need a parser. Walks lib/**/*.rb and
  # reports things like backup files, overly long methods, duplicate blocks,
  # and methods with too many positional parameters. Designed to be a fast
  # complement to rubocop/reek, not a replacement.
  class HeuristicScan
    Finding = Data.define(:path, :line, :rule, :message) do
      def to_s
        "#{path}:#{line} [#{rule}] #{message}"
      end
    end

    LONG_METHOD_LINES = 25
    LONG_FILE_LINES = 250
    MAX_POSITIONAL_PARAMS = 5
    DUPLICATE_MIN_LINES = 6
    DUPLICATE_MIN_COUNT = 3

    attr_reader :root

    def initialize(root: Rubycog.root)
      @root = root
    end

    def scan
      findings = []
      findings.concat(backup_files)
      ruby_files.each do |path|
        relative = relative_path(path)
        source = File.read(path)
        findings.concat(long_file(relative, source))
        findings.concat(long_methods(relative, source))
        findings.concat(too_many_params(relative, source))
        findings.concat(commented_code(relative, source))
      end
      findings.concat(duplicate_blocks)
      findings
    end

    private

    def ruby_files
      Dir.glob(File.join(root, 'lib', '**', '*.rb'))
    end

    def relative_path(path)
      path.sub(/\A#{Regexp.escape(root)}\/?/, '')
    end

    def backup_files
      Dir.glob(File.join(root, 'lib', '**', '*.bak')).map do |path|
        Finding.new(path: relative_path(path), line: 0, rule: 'BackupFile',
                    message: 'leftover .bak file should be deleted')
      end
    end

    def long_file(path, source)
      lines = source.lines.count
      return [] if lines < LONG_FILE_LINES

      [Finding.new(path: path, line: 0, rule: 'LongFile',
                   message: "#{lines} lines (threshold #{LONG_FILE_LINES})")]
    end

    # Approximate method boundaries with `def ... end` at column 0/2. We don't
    # need to be exact — false negatives are fine, false positives are not.
    def long_methods(path, source)
      findings = []
      lines = source.lines
      in_def = false
      def_indent = 0
      def_start = 0
      def_name = nil

      lines.each_with_index do |line, idx|
        if (m = line.match(/^(\s*)def\s+([\w.\[\]=<>?]+)/))
          in_def = true
          def_indent = m[1].length
          def_start = idx
          def_name = m[2]
        elsif in_def && line.match(/^\s{#{def_indent}}end\s*$/)
          length = idx - def_start + 1
          if length > LONG_METHOD_LINES
            findings << Finding.new(path: path, line: def_start + 1, rule: 'LongMethod',
                                    message: "#{def_name} spans #{length} lines (threshold #{LONG_METHOD_LINES})")
          end
          in_def = false
        end
      end
      findings
    end

    def too_many_params(path, source)
      findings = []
      source.each_line.with_index do |line, idx|
        m = line.match(/^\s*def\s+[\w.\[\]=<>?]+\s*\(([^)]*)\)/)
        next unless m

        params = m[1].split(',').map(&:strip).reject(&:empty?)
        positional = params.count { |p| !p.include?(':') && !p.start_with?('*', '&') }
        next unless positional > MAX_POSITIONAL_PARAMS

        findings << Finding.new(path: path, line: idx + 1, rule: 'TooManyParams',
                                message: "#{positional} positional parameters (threshold #{MAX_POSITIONAL_PARAMS})")
      end
      findings
    end

    def commented_code(path, source)
      findings = []
      source.each_line.with_index do |line, idx|
        next unless line.match(/^\s*#\s*(def |class |module |if |end|return |@\w+\s*=)/)

        findings << Finding.new(path: path, line: idx + 1, rule: 'CommentedCode',
                                message: 'commented-out code fragment; delete if dead')
      end
      findings
    end

    # Detect N-line blocks that appear in M or more distinct files. We hash
    # normalized (whitespace-stripped) blocks for speed.
    def duplicate_blocks
      blocks = Hash.new { |h, k| h[k] = [] }
      ruby_files.each do |path|
        relative = relative_path(path)
        lines = File.readlines(path).map(&:strip).reject(&:empty?)
        lines.each_cons(DUPLICATE_MIN_LINES).with_index do |chunk, idx|
          key = chunk.join("\n")
          next if key.length < 40  # skip trivially short blocks
          blocks[key] << [relative, idx + 1]
        end
      end

      findings = []
      blocks.each do |key, occurrences|
        files = occurrences.map(&:first).uniq
        next if files.size < DUPLICATE_MIN_COUNT

        # Report once per file so the message is actionable.
        occurrences.group_by(&:first).each do |file, list|
          findings << Finding.new(
            path: file, line: list.first[1], rule: 'DuplicateBlock',
            message: "#{DUPLICATE_MIN_LINES}-line block appears in #{files.size} files: #{files.join(', ')}"
          )
        end
      end
      findings
    end
  end
end
