# frozen_string_literal: true

require 'find'
require 'open3'
require 'timeout'

module Rubycog
  # Text index of documentation comments above classes, modules and methods in
  # the Ruby files of RubyCog and the current project. It is intentionally a
  # text approximation: no Ruby parser, no autoload, no runtime state.
  module SourceDocs
    Entry = Struct.new(
      :label, :kind, :name, :owner, :method_name, :class_method,
      :file, :path, :line, :comment, keyword_init: true
    )

    EXCLUDED_DIRS = %w[
      .git .rubycog .bundle node_modules vendor tmp log coverage build dist
      db storage pkg data
    ].freeze
    MAX_FILES = 500
    MAX_RESULTS = 50
    RI_TIMEOUT = 5

    module_function

    def roots
      normalize_roots([Rubycog.root, Dir.pwd])
    end

    def entries(roots: self.roots)
      root_list = normalize_roots(roots)
      files(root_list).flat_map { |path| scan(path, root_list) }
    end

    def files(root_list)
      result = []
      root_list.each do |root|
        Find.find(root) do |path|
          break if result.size >= MAX_FILES

          if File.directory?(path)
            base = File.basename(path)
            Find.prune if EXCLUDED_DIRS.include?(base) || (base.start_with?('.') && path != root)
            next
          end
          result << path if path.end_with?('.rb')
        end
        break if result.size >= MAX_FILES
      end
      result.sort.first(MAX_FILES)
    end

    def scan(path, root_list)
      found = []
      scope = [] # [module/class name, indent]
      comment = []
      display = display_path(path, root_list)

      File.foreach(path).with_index(1) do |raw, lineno|
        stripped = raw.strip
        indent = raw[/\A */].size

        if stripped.start_with?('#')
          text = stripped.sub(/\A#\s?/, '')
          comment << text unless text.match?(/\A(?:frozen_string_literal|encoding|coding):/)
          next
        end
        next if stripped.empty?

        if stripped.match?(/\Aend\b/)
          scope.pop while !scope.empty? && indent <= scope.last[1]
          comment = []
          next
        end

        if (match = stripped.match(/\A(class|module)\s+([A-Z][\w]*(?:::[A-Z][\w]*)*)/))
          name = if match[2].include?('::') || scope.empty?
                   match[2]
                 else
                   "#{scope.last[0]}::#{match[2]}"
                 end
          add_entry(found, label: "#{match[1]} #{name}", kind: match[1],
                          name: name, owner: name, file: display,
                          path: path, line: lineno, comment: comment)
          scope << [name, indent]
        elsif (match = stripped.match(/\Adef\s+(self\.)?([A-Za-z_]\w*[?!=]?|\[\]=?|<=>|===|==|=~|!~|!|\+@|-@|\*\*|<<|>>|[+\-*\/%&|^~<>]=?)/))
          owner = scope.empty? ? '(top-level)' : scope.last[0]
          class_method = !match[1].nil?
          label = "#{owner}#{class_method ? '.' : '#'}#{match[2]}"
          add_entry(found, label: label, kind: 'method', name: owner,
                          owner: owner, method_name: match[2],
                          class_method: class_method, file: display,
                          path: path, line: lineno, comment: comment)
        end

        comment = []
      end

      found
    rescue SystemCallError, EncodingError
      []
    end

    def search(query, roots: self.roots)
      words = query.to_s.split(/\s+/).map(&:downcase).reject(&:empty?)
      return [] if words.empty?

      entries(roots: roots).select do |entry|
        haystack = "#{entry.label} #{entry.comment} #{entry.file}".downcase
        words.all? { |word| haystack.include?(word) }
      end
    end

    def find(class_name:, method: nil, kind: 'instance', roots: self.roots)
      name = class_name.to_s
      labels = if method.to_s.empty?
                 ["class #{name}", "module #{name}"]
               else
                 ["#{name}#{kind.to_s == 'class' ? '.' : '#'}#{method}"]
               end
      entries(roots: roots).find { |entry| labels.include?(entry.label) }
    end

    def doc_for(class_name:, method: nil, kind: 'instance', roots: self.roots)
      entry = find(class_name: class_name, method: method, kind: kind, roots: roots)
      return entry.comment if entry

      ri_doc(ri_target(class_name, method, kind))
    end

    def source_for(entry)
      source_at(entry.path, entry.line)
    end

    def runtime_source(class_name:, method:, kind: 'instance')
      constant = Object.const_get(class_name.to_s)
      callable = if kind.to_s == 'class'
                   constant.method(method.to_s)
                 else
                   constant.instance_method(method.to_s)
                 end
      file, line = callable.source_location
      return nil unless file && File.file?(file)

      source_at(file, line)
    rescue NameError, TypeError
      nil
    end

    def source_at(path, line)
      return nil unless path && File.file?(path)

      lines = File.readlines(path)
      first = lines[line.to_i - 1]
      return nil unless first

      stripped = first.strip
      return stripped if stripped.match?(/\Adef\s+[^\s=]+(?:\([^)]*\))?\s*=\s*\S/)
      return stripped if stripped.match?(/\Adef\b.*\bend\b/)

      indent = first[/\A */].size
      out = [first]
      lines[line..].to_a.each do |raw|
        out << raw
        break if raw.strip.match?(/\Aend\b/) && raw[/\A */].size == indent
      end
      out.join.strip
    rescue SystemCallError, EncodingError
      nil
    end

    def ri_doc(target)
      return nil if target.to_s.empty?

      output, = Timeout.timeout(RI_TIMEOUT) do
        Open3.capture3('ri', '-f', 'markdown', '--no-pager', target)
      end
      text = output.gsub(/(.)\x08\1/, '\1').strip
      text.empty? || text.match?(/Nothing known about/i) ? nil : text
    rescue StandardError
      nil
    end

    def ri_target(class_name, method, kind)
      name = class_name.to_s
      return name if method.to_s.empty?

      "#{name}#{kind.to_s == 'class' ? '.' : '#'}#{method}"
    end

    def normalize_roots(candidates)
      Array(candidates).filter_map do |path|
        File.realpath(path) if File.directory?(path)
      end.uniq
    end

    def display_path(path, root_list)
      root = root_list.find { |candidate| path.start_with?("#{candidate}/") }
      root ? path.delete_prefix("#{root}/") : path
    end

    def add_entry(found, label:, kind:, name:, owner:, file:, path:, line:, comment:,
                  method_name: nil, class_method: false)
      return if comment.empty?

      found << Entry.new(
        label: label, kind: kind, name: name, owner: owner,
        method_name: method_name, class_method: class_method,
        file: file, path: path, line: line, comment: comment.join("\n")
      )
    end
  end
end
