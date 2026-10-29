# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'ruby_llm'
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

    # Stores the conversation, recording when each turn was written.
    #
    # The chat itself cannot carry a timestamp, so `stamps` is an optional
    # list of `{ role:, text:, at: }` in the order the screen showed them;
    # stamp matches them onto the stored turns (see below).
    def save(messages, stamps: nil)
      turns = self.class.stamp(self.class.extract(messages), stamps)
      @messages = turns.last(MAX_MESSAGES)
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
    #
    # A turn that already carries an ISO8601 'at' keeps it, so re-reading a
    # file and saving it again does not move the timestamps.
    def self.extract(messages)
      turns = []
      Array(messages).each do |message|
        role = field(message, :role).to_s
        content = field(message, :content)
        next unless ROLES.include?(role) && content.is_a?(String) && !content.strip.empty?

        if role == 'assistant' && turns.last && turns.last['role'] == 'assistant'
          turns.last['content'] = "#{turns.last['content']}\n\n#{content}"
        else
          turn = { 'role' => role, 'content' => content }
          at = field(message, :at)
          turn['at'] = at if time_string?(at)
          turns << turn
        end
      end
      turns
    end

    # True for a timestamp that can be read back, so a hand-edited or older
    # session file degrades to "no time" instead of crashing.
    def self.time_string?(value)
      return false unless value.is_a?(String) && !value.empty?

      Time.iso8601(value)
      true
    rescue ArgumentError
      false
    end

    # Copies the time each message appeared on screen onto the stored turn
    # that contains it.
    #
    # The two lists do not line up: one turn can span several tool rounds (so
    # extract merges several assistant messages), and compaction drops turns
    # from the chat while the screen keeps them. So both are walked in order,
    # and a turn takes the time of the first stamp whose text is its next
    # piece of content. A turn with no match stays untimestamped rather than
    # claiming the save time.
    def self.stamp(turns, stamps)
      entries = Array(stamps)
      cursor = 0
      turns.each do |turn|
        content = turn['content'].to_s
        position = 0
        start = (cursor...entries.length).find { |i| continues?(entries[i], turn['role'], content, position) }
        next unless start

        cursor = start
        turn['at'] ||= iso_time(entries[cursor][:at])
        while (entry = entries[cursor]) && continues?(entry, turn['role'], content, position)
          position += entry[:text].to_s.length + 2
          cursor += 1
        end
      end
      turns
    end

    # True when the entry is the next piece of the turn's text at `position`.
    def self.continues?(entry, role, content, position)
      text = entry[:text].to_s
      entry[:role].to_s == role && !text.empty? && content[position, text.length] == text
    end

    def self.iso_time(time)
      time.respond_to?(:utc) ? time.utc.iso8601 : nil
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
      payload = { 'version' => 2, 'updated_at' => Time.now.utc.iso8601, 'messages' => messages }
      tmp = "#{path}.#{Process.pid}.tmp"
      File.write(tmp, JSON.pretty_generate(payload))
      File.chmod(0o600, tmp)
      File.rename(tmp, path)
    rescue SystemCallError
      nil
    end
  end

  # Shrinks a long conversation into a short model-written briefing, so later
  # turns keep the thread without resending every earlier token.
  #
  # It works on the plain user/assistant turns that Session already extracts:
  # raw tool output is exactly what a summary should drop. The system prompt is
  # kept verbatim, and so are the newest turns, because the task in flight needs
  # its exact wording more than any summary of it.
  class Compactor
    KEEP_TURNS = 6
    MAX_TURNS = 40
    MAX_CHARS = 60_000

    PROMPT = <<~TEXT.freeze
      Summarize the conversation transcript below so your future self can carry
      on the work. Keep the user's goals and constraints, decisions and their
      reasons, files and commands touched, what was verified, and what is still
      open. Drop pleasantries, raw tool output, and anything that can simply be
      re-read from the repository. Reply with the summary only, as short
      bullets, in at most 300 words.
    TEXT

    def initialize(model: nil)
      @model = model
    end

    # True once resending the transcript costs more than one summary call.
    # Tool output counts toward the size: it is never summarized, but it is the
    # most common reason a step no longer fits. The system prompt is ignored
    # because compaction keeps it either way.
    def needed?(messages)
      list = Array(messages)
      size = list.reject { |message| Session.field(message, :role).to_s == 'system' }
                 .sum { |message| Session.field(message, :content).to_s.length }
      Session.extract(list).length > MAX_TURNS || size > MAX_CHARS
    end

    # Rewrites the history as: system prompt, briefing, newest turns.
    # Returns the summary text, or nil when the history is short enough to keep.
    def compact(chat)
      turns = Session.extract(chat.messages)
      older = turns[0...-KEEP_TURNS]
      return nil if older.length < 2

      summary = summarize(older)
      return nil unless summary

      chat.messages = system_messages(chat.messages) + rebuilt(turns, summary)
      summary
    end

    def summarize(turns)
      prompt = "#{PROMPT}\n\n--- transcript ---\n#{transcript(turns)}"
      text = RubyLLM.chat(model: @model).ask(prompt).content.to_s.strip
      text.empty? ? nil : text
    end

    def transcript(turns)
      turns.map { |turn| "#{turn['role']}: #{turn['content']}" }.join("\n\n")
    end

    def briefing(summary)
      "Compacted summary of the earlier conversation:\n\n#{summary}"
    end

    private

    def system_messages(messages)
      Array(messages).select { |message| Session.field(message, :role).to_s == 'system' }
    end

    def tail(turns)
      turns.last(KEEP_TURNS).map { |turn| { role: turn['role'], content: turn['content'] } }
    end

    # The briefing joins the first kept user turn when there is one, so the
    # history still alternates instead of ending on two user turns in a row.
    def rebuilt(turns, summary)
      kept = tail(turns)
      return [{ role: 'user', content: briefing(summary) }] + kept unless kept.first&.fetch(:role) == 'user'

      kept[0] = { role: 'user', content: "#{briefing(summary)}\n\n#{kept.first[:content]}" }
      kept
    end
  end
end
