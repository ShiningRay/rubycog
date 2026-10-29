# frozen_string_literal: true

require_relative 'test_helper'
require 'fileutils'
require 'tmpdir'

class SourceDocsTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('rubycog-docs')
    @lib = File.join(@dir, 'lib', 'demo')
    FileUtils.mkdir_p(@lib)
    File.write(File.join(@lib, 'greeter.rb'), <<~RUBY)
      # Greeter builds messages.
      module Demo
        # Says hello.
        class Greeter
          # Returns a greeting.
          # Adds the name.
          def greet(name)
            "hello \#{name}"
          end

          # Default greeting.
          def self.default
            "hello"
          end

          # Short greeting.
          def short = "hi"
        end
      end
    RUBY
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_indexes_modules_classes_and_methods
    labels = Rubycog::SourceDocs.entries(roots: [@dir]).map(&:label)

    assert_includes labels, 'module Demo'
    assert_includes labels, 'class Demo::Greeter'
    assert_includes labels, 'Demo::Greeter#greet'
    assert_includes labels, 'Demo::Greeter.default'
    assert_includes labels, 'Demo::Greeter#short'
  end

  def test_search_requires_all_words
    hits = Rubycog::SourceDocs.search('greeting name', roots: [@dir])

    assert_equal ['Demo::Greeter#greet'], hits.map(&:label)
  end

  def test_doc_for_class_and_method
    assert_includes Rubycog::SourceDocs.doc_for(class_name: 'Demo::Greeter', roots: [@dir]),
      'Says hello.'
    assert_includes Rubycog::SourceDocs.doc_for(class_name: 'Demo::Greeter', method: 'greet', roots: [@dir]),
      'Returns a greeting.'
  end

  def test_source_for_method_stops_at_matching_end
    entry = Rubycog::SourceDocs.find(class_name: 'Demo::Greeter', method: 'greet', roots: [@dir])

    source = Rubycog::SourceDocs.source_for(entry)

    assert_includes source, 'def greet(name)'
    assert_includes source, 'end'
    refute_includes source, 'def self.default'
  end

  def test_source_for_endless_method
    entry = Rubycog::SourceDocs.find(class_name: 'Demo::Greeter', method: 'short', roots: [@dir])

    assert_equal 'def short = "hi"', Rubycog::SourceDocs.source_for(entry)
  end

  def test_ignores_excluded_directories
    FileUtils.mkdir_p(File.join(@dir, '.git'))
    File.write(File.join(@dir, '.git', 'ignored.rb'), "# ignored docs\nclass Ignored\nend\n")

    assert_empty Rubycog::SourceDocs.search('ignored', roots: [@dir])
  end

  def test_ignores_magic_comments
    File.write(File.join(@lib, 'magic.rb'), "# frozen_string_literal: true\n\n# Real doc.\nmodule Magic\nend\n")

    assert_empty Rubycog::SourceDocs.search('frozen_string_literal', roots: [@dir])
  end
end

class SourceDocsToolsTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('rubycog-docs-tools')
    @lib = File.join(@dir, 'lib')
    FileUtils.mkdir_p(@lib)
    File.write(File.join(@lib, 'greeter.rb'), <<~RUBY)
      # Greeter builds messages.
      class Greeter
        # Returns a greeting.
        def greet(name)
          "hello \#{name}"
        end
      end
    RUBY
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_search_docs_tool
    output = Rubycog::SearchDocsTool.new(roots: [@dir]).execute(query: 'greeting')

    assert_includes output, 'Greeter#greet'
    assert_includes output, 'lib/greeter.rb:4'
  end

  def test_get_doc_tool
    output = Rubycog::GetDocTool.new(roots: [@dir]).execute(class_name: 'Greeter')

    assert_includes output, 'Greeter builds messages.'
  end

  def test_get_source_tool
    output = Rubycog::GetSourceTool.new(roots: [@dir]).execute(class_name: 'Greeter', method: 'greet')

    assert_includes output, 'def greet(name)'
    assert_includes output, 'end'
  end

  def test_get_source_reports_missing_methods
    output = Rubycog::GetSourceTool.new(roots: [@dir]).execute(class_name: 'Greeter', method: 'missing')

    assert_includes output, 'no Ruby source for Greeter#missing'
  end
end
