# frozen_string_literal: true

require_relative 'test_helper'
require 'tmpdir'
require 'fileutils'

class ExperienceTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('rubycog-exp')
    @store = Rubycog::Experience.new(dir: @dir)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_create_and_find_roundtrip
    entry = @store.create(
      source: 'https://example.com/post',
      summary: 'Use skill bundles to load capabilities on demand',
      tags: %w[Agent Skills],
      applicable_to: %w[tool_design],
      patterns: [
        { 'name' => 'skill_bundle', 'idea' => 'Each skill in own dir with SKILL.md', 'rubycog_fit' => 'Map to tools/<name>/' }
      ],
      confidence: 'high'
    )

    assert entry['id'].start_with?('exp-')
    assert_equal ['agent', 'skills'], entry['tags']
    assert_equal 1, entry['patterns'].size

    found = @store.find(entry['id'])
    assert_equal entry['summary'], found['summary']
    assert_equal entry['patterns'], found['patterns']
  end

  def test_create_rejects_duplicate_source
    @store.create(source: 'https://example.com/x', summary: 'first')

    err = assert_raises(ArgumentError) do
      @store.create(source: 'https://example.com/x', summary: 'second')
    end
    assert_match(/already exists/, err.message)
  end

  def test_create_requires_source_and_summary
    assert_raises(ArgumentError) { @store.create(source: '', summary: 'x') }
    assert_raises(ArgumentError) { @store.create(source: 'https://a', summary: ' ') }
  end

  def test_create_validates_confidence
    assert_raises(ArgumentError) do
      @store.create(source: 'https://a', summary: 'x', confidence: 'wild')
    end
  end

  def test_search_ands_words_case_insensitively
    @store.create(source: 'https://a/1', summary: 'Skill bundles for tools', tags: %w[agent])
    @store.create(source: 'https://a/2', summary: 'Retry logic for LLM calls', tags: %w[network])
    @store.create(source: 'https://a/3', summary: 'Skill loading from YAML', tags: %w[agent skills])

    hits = @store.search('skill')
    assert_equal 2, hits.size

    hits = @store.search('SKILL agent')
    assert_equal 2, hits.size

    hits = @store.search('skill retry')
    assert_empty hits
  end

  def test_search_matches_pattern_fields
    @store.create(
      source: 'https://a/p',
      summary: 'Generic',
      patterns: [{ 'name' => 'backoff', 'idea' => 'Exponential backoff with jitter', 'rubycog_fit' => 'Add to chat.ask' }]
    )

    assert_equal 1, @store.search('backoff').size
    assert_equal 1, @store.search('jitter').size
    assert_equal 1, @store.search('chat.ask').size
  end

  def test_empty_query_returns_all
    @store.create(source: 'https://a/1', summary: 'one')
    @store.create(source: 'https://a/2', summary: 'two')

    assert_equal 2, @store.search('').size
    assert_equal 2, @store.all.size
  end

  def test_delete_removes_file
    entry = @store.create(source: 'https://a/1', summary: 'one')

    assert @store.delete(entry['id'])
    assert_nil @store.find(entry['id'])
    refute @store.delete(entry['id'])
  end

  def test_load_tolerates_hand_edited_missing_fields
    path = File.join(@dir, 'exp-hand.yaml')
    File.write(path, { 'id' => 'exp-hand', 'source' => 'https://x', 'summary' => 'short' }.to_yaml)

    entries = @store.all
    assert_equal 1, entries.size
    assert_equal [], entries.first['tags']
    assert_equal [], entries.first['patterns']
  end

  def test_to_line_and_to_text
    entry = @store.create(source: 'https://a', summary: 'x' * 200)
    line = Rubycog::Experience.to_line(entry)
    assert line.length < 200

    text = Rubycog::Experience.to_text(entry)
    assert_includes text, "source: https://a"
    assert_includes text, 'summary:'
  end

  def test_summary_truncated_to_limit
    entry = @store.create(source: 'https://a', summary: 'x' * 5_000)
    assert_equal Rubycog::Experience::MAX_SUMMARY, entry['summary'].length
  end
end

class WebFetcherTest < Minitest::Test
  def test_parse_uri_rejects_non_http
    fetcher = Rubycog::WebFetcher.new
    result = fetcher.fetch('file:///etc/passwd')
    refute result.ok?
    assert_match(/unsupported scheme/, result.error)
  end

  def test_parse_uri_rejects_garbage
    fetcher = Rubycog::WebFetcher.new
    result = fetcher.fetch('not a url')
    refute result.ok?
  end

  def test_html_to_text_strips_scripts_and_tags
    fetcher = Rubycog::WebFetcher.new
    html = <<~HTML
      <html><head><style>body { color: red }</style></head>
      <body><h1>Title</h1><p>Hello &amp; <b>world</b></p>
      <script>alert(1)</script>
      <p>Second<br>line</p></body></html>
    HTML
    text = fetcher.send(:html_to_text, html)
    refute_includes text, 'alert'
    refute_includes text, 'color: red'
    refute_includes text, '<b>'
    assert_includes text, 'Title'
    assert_includes text, 'Hello & world'
    assert_includes text, "Second\nline"
  end
end

class ExperienceToolsTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('rubycog-exp-tools')
    @store = Rubycog::Experience.new(dir: @dir)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_save_experience_tool_persists
    tool = Rubycog::SaveExperienceTool.new(store: @store)
    out = tool.execute(source: 'https://a', summary: 'Idea', tags: %w[x])
    assert_includes out, 'saved experience'
    assert_equal 1, @store.all.size
  end

  def test_save_experience_tool_rejects_dupe
    tool = Rubycog::SaveExperienceTool.new(store: @store)
    tool.execute(source: 'https://a', summary: 'first')
    out = tool.execute(source: 'https://a', summary: 'second')
    assert_includes out, 'error'
    assert_includes out, 'already exists'
  end

  def test_search_experiences_tool_formats_lines
    @store.create(source: 'https://a', summary: 'Skill bundles', tags: %w[agent])
    tool = Rubycog::SearchExperiencesTool.new(store: @store)

    out = tool.execute(query: 'skill')
    assert_includes out, 'Skill bundles'
    assert_includes out, '(1 matches)'
  end

  def test_search_experiences_tool_full_mode
    @store.create(source: 'https://a', summary: 'Skill bundles')
    tool = Rubycog::SearchExperiencesTool.new(store: @store)

    out = tool.execute(query: 'skill', full: true)
    assert_includes out, 'source: https://a'
  end

  def test_search_experiences_tool_empty
    tool = Rubycog::SearchExperiencesTool.new(store: @store)
    out = tool.execute(query: 'zzz')
    assert_includes out, 'no experiences matched'
  end

  def test_learn_from_url_tool_uses_injected_fetcher
    fake = Class.new do
      def self.fetch(_url)
        Rubycog::WebFetcher::Result.new(url: 'https://a', status: 200,
                                        content_type: 'text/plain', body: 'hello', error: nil)
      end
    end
    tool = Rubycog::LearnFromUrlTool.new(fetcher: fake)
    out = tool.execute(url: 'https://a')
    assert_includes out, 'Status: 200'
    assert_includes out, 'hello'
    assert_includes out, 'save_experience'
  end

  def test_learn_from_url_tool_propagates_fetch_error
    fake = Class.new do
      def self.fetch(_url)
        Rubycog::WebFetcher::Result.new(url: 'https://a', status: 0,
                                        content_type: '', body: '', error: 'connection refused')
      end
    end
    tool = Rubycog::LearnFromUrlTool.new(fetcher: fake)
    out = tool.execute(url: 'https://a')
    assert_includes out, 'connection refused'
  end

  def test_learn_from_url_tool_requires_url
    tool = Rubycog::LearnFromUrlTool.new
    assert_includes tool.execute(url: ''), 'url is required'
  end
end
