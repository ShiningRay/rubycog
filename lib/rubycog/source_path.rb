# frozen_string_literal: true

module Rubycog
  # Guards which project files self-iteration tools may read or write.
  module SourcePath
    ALLOWED = [
      %r{\Alib/.+\.rb\z},
      %r{\Atest/.+\.rb\z},
      %r{\Adocs/.+\.md\z},
      %r{\Abin/rubycog\z},
      %r{\AREADME\.md\z},
      %r{\AGemfile\z},
      %r{\Arubycog\.gemspec\z}
    ].freeze

    FORBIDDEN = [
      %r{\A\.git/},
      %r{\A\.rubycog/},
      %r{\A\.env},
      %r{\Atmp/},
      %r{\Avendor/},
      %r{\.pem\z},
      %r{\.key\z},
      %r{\AGemfile\.lock\z}
    ].freeze

    # The editor and its audit/state layer stay human-owned: a bad edit there
    # can break every later self-edit. Reads are still allowed.
    PROTECTED_FOR_WRITE = %w[
      lib/rubycog/source_path.rb
      lib/rubycog/source_edit.rb
      lib/rubycog/self_iteration.rb
      lib/rubycog/tools/edit_source.rb
    ].freeze

    module_function

    # Returns [absolute_path, relative_path]. Relative paths only; absolute
    # paths and symlinks that escape the project root are rejected.
    def resolve(path, root: Rubycog.root, must_exist: true, write: false)
      relative = normalize(path)
      validate!(relative)
      if write && PROTECTED_FOR_WRITE.include?(relative)
        raise ArgumentError, "file is protected from self-edits: #{relative}"
      end

      root_path = File.expand_path(root)
      full = File.expand_path(relative, root_path)
      root_real = File.exist?(root_path) ? File.realpath(root_path) : root_path
      prefix = "#{root_real}/"

      if File.exist?(full)
        real = File.realpath(full)
        raise ArgumentError, "path escapes project root: #{relative}" unless real.start_with?(prefix)
      else
        raise ArgumentError, "file not found: #{relative}" if must_exist

        parent = File.dirname(full)
        raise ArgumentError, "parent directory is missing: #{relative}" unless File.directory?(parent)

        real_parent = File.realpath(parent)
        unless real_parent == root_real || real_parent.start_with?(prefix)
          raise ArgumentError, "path escapes project root: #{relative}"
        end
      end

      [full, relative]
    end

    def normalize(path)
      text = path.to_s.strip
      raise ArgumentError, 'path is required' if text.empty?
      raise ArgumentError, 'null byte in path' if text.include?("\0")
      raise ArgumentError, 'absolute paths are not allowed' if text.start_with?('/')

      text = text.delete_prefix('./')
      raise ArgumentError, 'empty path' if text.empty?
      if text.split('/').any? { |segment| segment == '.' || segment == '..' }
        raise ArgumentError, "path traversal is not allowed: #{text}"
      end

      text
    end

    def validate!(relative)
      if FORBIDDEN.any? { |pattern| relative.match?(pattern) }
        raise ArgumentError, "path is forbidden: #{relative}"
      end
      return if ALLOWED.any? { |pattern| relative.match?(pattern) }

      raise ArgumentError, "path is not editable: #{relative}"
    end
  end
end
