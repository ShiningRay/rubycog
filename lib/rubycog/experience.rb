# frozen_string_literal: true

require 'fileutils'
require 'yaml'
require 'time'
require 'digest'

module Rubycog
  # Persistent store for "experiences" — distilled patterns learned from
  # external sources (other agents, blog posts, papers) that RubyCog can later
  # consult before changing itself. One YAML file per experience under
  # .rubycog/experiences/ next to the project root. Deliberately plain files
  # so users can edit, delete or version them.
  class Experience
    DEFAULT_DIR = File.join(Rubycog.root, '.rubycog', 'experiences').freeze
    FIELDS = %w[id source learned_at tags summary applicable_to patterns confidence notes].freeze
    CONFIDENCE = %w[low medium high].freeze
    MAX_SUMMARY = 1_000
    MAX_PATTERN_IDEA = 500

    attr_reader :dir

    def initialize(dir: DEFAULT_DIR)
      @dir = dir
    end

    # Returns all experiences as plain hashes, newest first.
    def all
      Dir.glob(File.join(dir, '*.yaml')).sort.reverse.filter_map do |path|
        load_file(path)
      end
    end

    def find(id)
      all.find { |entry| entry['id'] == id }
    end

    # AND-search over summary, tags, source, applicable_to, and pattern text.
    # Case-insensitive. Empty query returns everything.
    def search(query)
      words = query.to_s.downcase.split(/\s+/).reject(&:empty?)
      return all if words.empty?

      all.select do |entry|
        haystack = searchable_text(entry)
        words.all? { |word| haystack.include?(word) }
      end
    end

    # Persist a new experience. Required: source, summary. Returns the stored
    # hash including the generated id. Rejects duplicates by source URL.
    def create(source:, summary:, tags: [], applicable_to: [], patterns: [], confidence: 'medium', notes: nil)
      raise ArgumentError, 'source is required' if source.to_s.strip.empty?
      raise ArgumentError, 'summary is required' if summary.to_s.strip.empty?
      raise ArgumentError, "confidence must be one of #{CONFIDENCE.join(', ')}" unless CONFIDENCE.include?(confidence)

      source = source.strip
      if (existing = all.find { |e| e['source'] == source })
        raise ArgumentError, "experience already exists for this source: #{existing['id']}"
      end

      entry = {
        'id' => generate_id(source),
        'source' => source,
        'learned_at' => Time.now.utc.iso8601,
        'tags' => Array(tags).map { |t| t.to_s.strip.downcase }.reject(&:empty?).uniq,
        'summary' => summary.strip[0, MAX_SUMMARY],
        'applicable_to' => Array(applicable_to).map(&:to_s),
        'patterns' => normalize_patterns(patterns),
        'confidence' => confidence
      }
      entry['notes'] = notes.strip[0, MAX_SUMMARY] if notes && !notes.strip.empty?

      FileUtils.mkdir_p(dir)
      path = File.join(dir, "#{entry['id']}.yaml")
      File.write(path, YAML.dump(entry))
      entry
    end

    def delete(id)
      path = File.join(dir, "#{id}.yaml")
      return false unless File.exist?(path)

      File.delete(path)
      true
    end

    # Render a one-line summary suitable for tool output.
    def self.to_line(entry)
      tags = entry['tags'].empty? ? '' : " [#{entry['tags'].join(', ')}]"
      "#{entry['id']}#{tags} — #{entry['summary'][0, 120]}"
    end

    # Render the full experience as readable text for the agent.
    def self.to_text(entry)
      lines = []
      lines << "id: #{entry['id']}"
      lines << "source: #{entry['source']}"
      lines << "learned_at: #{entry['learned_at']}"
      lines << "confidence: #{entry['confidence']}"
      lines << "tags: #{entry['tags'].join(', ')}" unless entry['tags'].empty?
      lines << "applicable_to: #{entry['applicable_to'].join(', ')}" unless entry['applicable_to'].empty?
      lines << "summary: #{entry['summary']}"
      unless entry['patterns'].empty?
        lines << 'patterns:'
        entry['patterns'].each do |p|
          lines << "  - #{p['name']}: #{p['idea']}"
          lines << "    rubycog_fit: #{p['rubycog_fit']}" if p['rubycog_fit']
        end
      end
      lines << "notes: #{entry['notes']}" if entry['notes']
      lines.join("\n")
    end

    private

    def load_file(path)
      data = YAML.safe_load_file(path, permitted_classes: [Time, Date], aliases: false)
      return nil unless data.is_a?(Hash)

      # Fill missing keys so search and render do not crash on hand-edited files.
      FIELDS.each { |k| data[k] ||= default_for(k) }
      data
    rescue StandardError
      nil
    end

    def default_for(key)
      case key
      when 'tags', 'applicable_to', 'patterns' then []
      else ''
      end
    end

    def searchable_text(entry)
      parts = [entry['source'], entry['summary'], entry['notes'],
               entry['tags'].join(' '), entry['applicable_to'].join(' ')]
      entry['patterns'].each do |p|
        parts << p['name'] << p['idea'] << p['rubycog_fit']
      end
      parts.compact.join(' ').downcase
    end

    def normalize_patterns(patterns)
      Array(patterns).filter_map do |p|
        next nil unless p.is_a?(Hash)
        name = (p['name'] || p[:name]).to_s.strip
        idea = (p['idea'] || p[:idea]).to_s.strip
        next nil if name.empty? || idea.empty?

        fit = (p['rubycog_fit'] || p[:rubycog_fit]).to_s.strip
        result = { 'name' => name, 'idea' => idea[0, MAX_PATTERN_IDEA] }
        result['rubycog_fit'] = fit[0, MAX_PATTERN_IDEA] unless fit.empty?
        result
      end
    end

    def generate_id(source)
      digest = Digest::SHA256.hexdigest(source)[0, 8]
      "exp-#{Time.now.utc.strftime('%Y%m%d')}-#{digest}"
    end
  end
end
