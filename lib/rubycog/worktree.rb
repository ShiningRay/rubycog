# frozen_string_literal: true

require 'open3'
require 'fileutils'
require 'shellwords'
require 'timeout'

module Rubycog
  # Thin wrapper around `git worktree` so the evolution executor can run in an
  # isolated checkout. Deliberately uses the system git binary via Open3 with
  # an explicit argv (no shell interpolation), a hard timeout, and the project
  # root as chdir. Raises Worktree::Error on any failure.
  class Worktree
    class Error < StandardError; end

    DEFAULT_BASE = File.join(Rubycog.root, '.rubycog', 'worktrees').freeze
    GIT_TIMEOUT = 30

    attr_reader :root, :base

    def initialize(root: Rubycog.root, base: DEFAULT_BASE)
      @root = root
      @base = base
    end

    # Create a new worktree + branch from the current HEAD. Returns the
    # absolute path to the worktree. Branch name: evo/<proposal_id>.
    def create(proposal_id, from: 'HEAD')
      ensure_git_repo!
      FileUtils.mkdir_p(base)

      path = File.join(base, proposal_id)
      branch = "evo/#{proposal_id}"
      raise Error, "worktree already exists: #{path}" if File.exist?(path)

      run!('worktree', 'add', '-b', branch, path, from)
      path
    end

    # Remove a worktree and delete its branch. Idempotent — missing worktrees
    # are not an error.
    def remove(proposal_id, force: true)
      path = File.join(base, proposal_id)
      branch = "evo/#{proposal_id}"
      if File.exist?(path)
        args = %w[worktree remove]
        args << '--force' if force
        args << path
        run!(*args)
      end
      # Branch may not exist if creation failed midway; ignore the error.
      run('branch', '-D', branch) if branch_exists?(branch)
      true
    end

    def path_for(proposal_id)
      File.join(base, proposal_id)
    end

    def branch_for(proposal_id)
      "evo/#{proposal_id}"
    end

    def exist?(proposal_id)
      File.directory?(path_for(proposal_id))
    end

    # Run a git command inside the worktree (e.g. status, diff).
    def inside(proposal_id, *args)
      path = path_for(proposal_id)
      raise Error, "worktree does not exist: #{path}" unless File.directory?(path)

      run!('-C', path, *args)
    end

    private

    def ensure_git_repo!
      run!('rev-parse', '--git-dir')
    rescue Error => e
      raise Error, "not a git repository: #{root} (#{e.message})"
    end

    def branch_exists?(name)
      run('rev-parse', '--verify', name).success?
    end

    def run(*args)
      Open3.popen3('git', *args, chdir: root) do |stdin, stdout, stderr, wait|
        stdin.close
        out = stdout.read
        err = stderr.read
        status = wait.value
        Result.new(status: status, stdout: out, stderr: err)
      end
    rescue SystemCallError => e
      raise Error, "git invocation failed: #{e.class}: #{e.message}"
    end

    def run!(*args)
      result = with_timeout { run(*args) }
      return result if result.success?

      raise Error, "git #{args.join(' ')} failed (exit #{result.status.exitstatus}): #{result.stderr.strip}"
    end

    def with_timeout
      Timeout.timeout(GIT_TIMEOUT) { yield }
    rescue Timeout::Error
      raise Error, "git command timed out after #{GIT_TIMEOUT}s"
    end

    Result = Data.define(:status, :stdout, :stderr) do
      def success? = status.success?
    end
  end
end
