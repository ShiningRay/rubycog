# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'time'

module Rubycog
  # Keeps the conversation on disk so the next launch can restore it.
  #
  # Only plain user/assistant text turns are stored. Tool calls and tool
  # results are session-local: replaying them would either fail or confuse
  # the model, so they are dropped on save.
  class Session
    DEFAULT_FILE = '.rubycog_session.json'
    MAX_MESSAGES = 200
    ROLES = %w[user assistant].freeze

    attr_reader :path, :messages

    def self.default_path(env: ENV)
      from_env = env['RUBYCOG_SESSION'].to_s.strip
      File.expand_path(from_env.empty? ? DEFAULT_FILE : from_env)
    end

    # Reads a stored session; a missing or corrupt file just yields an empty one.
    def initialize(path = self.class.default_path)
      @path = path
      @messages = read
    end

    # Replays stored turns into a RubyLLM chat so the agent keeps its context.
    def restore(chat)
      messages.each { |message| chat.add_message(role: message['role'], content: message['content']) }
      self
    end

    def save(messages)
      @messages = self.class.extract(messages).last(MAX_MESSAGES)
      write
      self
    end

    def clear
      @messages = []
      FileUtils.rm_f(path) if path
      self
    end

    def empty? = messages.empty?

    # Normalizes RubyLLM::Message objects or plain hashes into stored turns.
    # Consecutive assistant text messages are merged: tool-call rounds produce
    # several assistant messages, and replaying them as separate turns makes
    # the restored conversation look like the model talked to itself.
    def self.extract(messages)
      turns = []
      Array(messages).each do |message|
        role = field(message, :role).to_s
        content = field(message, :content)
        next unless ROLES.include?(role) && content.is_a?(String) && !content.strip.empty?

        if role == 'assistant' && turns.last && turns.last['role'] == 'assistant'
          turns.last['content'] = "#{turns.last['content']}\n\n#{content}"
        else
          turns << { 'role' => role, 'content' => content }
        end
      end
      turns
    end

    def self.field(message, name)
      return message.public_send(name) if message.respond_to?(name)
      return unless message.is_a?(Hash)

      message[name] || message[name.to_s]
    end

    private

    def read
      return [] unless path && File.exist?(path)

      data = JSON.parse(File.read(path))
      self.class.extract(data.is_a?(Hash) ? data['messages'] : data)
    rescue JSON::ParserError, SystemCallError
      []
    end

    # Write to a temp file and rename, so an interrupted save never leaves a
    # half-written history behind.
    def write
      return unless path

      FileUtils.mkdir_p(File.dirname(path))
      payload = { 'version' => 1, 'updated_at' => Time.now.utc.iso8601, 'messages' => messages }
      tmp = "#{path}.#{Process.pid}.tmp"
      File.write(tmp, JSON.pretty_generate(payload))
      File.chmod(0o600, tmp)
      File.rename(tmp, path)
    rescue SystemCallError
      nil
    end
  end
end
