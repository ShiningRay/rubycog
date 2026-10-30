# frozen_string_literal: true

require 'fileutils'
require 'yaml'
require 'time'
require 'digest'

module Rubycog
  # A Proposal is a persisted request to change RubyCog itself. It records the
  # motivation (often an Experience id), the expected benefit, the risk, and
  # the budget. Proposals go through an explicit state machine and never edit
  # code on their own — the Evolution::Executor is the only writer.
  #
  # States:
  #   proposed   → written by the model, awaiting human approval
  #   approved   → human approved, ready to run
  #   running    → executor is working in a worktree
  #   evaluated  → tests + comparison finished, merge recommendation recorded
  #   merged     → user merged the worktree branch back
  #   rejected   → human rejected
  #   failed     → execution or evaluation failed; see result
  #   rolled_back→ user rolled the change back
  class Proposal
    DEFAULT_DIR = File.join(Rubycog.root, '.rubycog', 'proposals').freeze
    STATES = %w[proposed approved running evaluated merged rejected failed rolled_back].freeze
    CATEGORIES = %w[feature refactor performance].freeze
    TRANSITIONS = {
      'proposed' => %w[approved rejected],
      'approved' => %w[running rejected],
      'running' => %w[evaluated failed],
      'evaluated' => %w[merged rolled_back],
      'failed' => %w[approved rejected rolled_back],
      'merged' => [],
      'rejected' => [],
      'rolled_back' => []
    }.freeze
    FIELDS = %w[id title status category motivation experience_id expected_benefit risk
                touches test_plan budget created_at updated_at result].freeze
    DEFAULT_BUDGET = { 'max_files' => 3, 'max_lines' => 120 }.freeze

    attr_reader :dir

    def initialize(dir: DEFAULT_DIR)
      @dir = dir
    end

    def all
      Dir.glob(File.join(dir, '*.yaml')).sort.reverse.filter_map { |p| load_file(p) }
    end

    def find(id)
      all.find { |e| e['id'] == id }
    end

    def list(status: nil)
      status ? all.select { |e| e['status'] == status } : all
    end

    def create(title:, motivation:, expected_benefit: '', risk: '',
               touches: [], test_plan: '', budget: {}, experience_id: nil,
               category: 'feature')
      raise ArgumentError, 'title is required' if title.to_s.strip.empty?
      raise ArgumentError, 'motivation is required' if motivation.to_s.strip.empty?
      unless CATEGORIES.include?(category)
        raise ArgumentError, "category must be one of #{CATEGORIES.join(', ')}"
      end

      now = Time.now.utc.iso8601
      entry = {
        'id' => generate_id(title),
        'title' => title.strip,
        'status' => 'proposed',
        'category' => category,
        'motivation' => motivation.strip,
        'experience_id' => experience_id,
        'expected_benefit' => expected_benefit.to_s.strip,
        'risk' => risk.to_s.strip,
        'touches' => Array(touches).map(&:to_s),
        'test_plan' => test_plan.to_s.strip,
        'budget' => DEFAULT_BUDGET.merge(stringify(budget)),
        'created_at' => now,
        'updated_at' => now,
        'result' => nil
      }
      persist(entry)
      entry
    end

    # Move a proposal to a new state. Enforces TRANSITIONS. `result` is merged
    # into any existing result hash so callers do not lose worktree_path or
    # branch recorded earlier.
    def transition(id, to, result: nil)
      entry = find(id)
      raise ArgumentError, "proposal not found: #{id}" unless entry

      from = entry['status']
      allowed = TRANSITIONS.fetch(from, [])
      unless allowed.include?(to)
        raise ArgumentError, "cannot transition #{id} from #{from} to #{to} (allowed: #{allowed.join(', ')})"
      end

      entry['status'] = to
      entry['updated_at'] = Time.now.utc.iso8601
      entry['result'] = (entry['result'] || {}).merge(stringify(result)) if result
      persist(entry)
      entry
    end

    # Update arbitrary result hash without changing state (used by executor
    # to attach worktree path, branch name, test output, etc.).
    def attach_result(id, data)
      entry = find(id)
      raise ArgumentError, "proposal not found: #{id}" unless entry

      entry['result'] = (entry['result'] || {}).merge(stringify(data))
      entry['updated_at'] = Time.now.utc.iso8601
      persist(entry)
      entry
    end

    def self.to_line(entry)
      cat = entry['category'].to_s.empty? ? '' : "/#{entry['category']}"
      "[#{entry['status']}#{cat}] #{entry['id']} — #{entry['title']}"
    end

    def self.to_text(entry)
      lines = []
      lines << "id: #{entry['id']}"
      lines << "title: #{entry['title']}"
      lines << "status: #{entry['status']}"
      lines << "category: #{entry['category']}"
      lines << "motivation: #{entry['motivation']}"
      lines << "experience_id: #{entry['experience_id']}" if entry['experience_id']
      lines << "expected_benefit: #{entry['expected_benefit']}" unless entry['expected_benefit'].to_s.empty?
      lines << "risk: #{entry['risk']}" unless entry['risk'].to_s.empty?
      lines << "touches: #{entry['touches'].join(', ')}" unless entry['touches'].empty?
      lines << "test_plan: #{entry['test_plan']}" unless entry['test_plan'].to_s.empty?
      lines << "budget: max_files=#{entry['budget']['max_files']} max_lines=#{entry['budget']['max_lines']}"
      lines << "created_at: #{entry['created_at']}"
      lines << "updated_at: #{entry['updated_at']}"
      if entry['result'] && !entry['result'].empty?
        lines << 'result:'
        entry['result'].each { |k, v| lines << "  #{k}: #{v}" }
      end
      lines.join("\n")
    end

    private

    def load_file(path)
      data = YAML.safe_load_file(path, permitted_classes: [Time, Date], aliases: false)
      return nil unless data.is_a?(Hash)

      FIELDS.each { |k| data[k] ||= default_for(k) }
      data
    rescue StandardError
      nil
    end

    def default_for(key)
      case key
      when 'touches' then []
      when 'budget' then DEFAULT_BUDGET.dup
      when 'category' then 'feature'
      else nil
      end
    end

    def stringify(hash)
      return {} unless hash.is_a?(Hash)

      hash.each_with_object({}) { |(k, v), acc| acc[k.to_s] = v }
    end

    def persist(entry)
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "#{entry['id']}.yaml")
      File.write(path, YAML.dump(entry))
    end

    def generate_id(title)
      slug = title.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/\A-|-$\z?/, '')[0, 40]
      slug = 'proposal' if slug.empty?
      digest = Digest::SHA256.hexdigest("#{title}#{Time.now.utc.to_f}")[0, 6]
      "prop-#{slug}-#{digest}"
    end
  end
end
