# frozen_string_literal: true

require 'io/console'

module Rubycog
  module Text
    module_function

    def width(text)
      text.each_char.sum do |char|
        next 0 if char.ord < 32
        next 2 if wide?(char)

        1
      end
    end

    def wide?(char)
      codepoint = char.ord
      codepoint.between?(0x1100, 0x115f) ||
        codepoint.between?(0x2e80, 0xa4cf) ||
        codepoint.between?(0xac00, 0xd7a3) ||
        codepoint.between?(0xf900, 0xfaff) ||
        codepoint.between?(0xfe30, 0xfe4f) ||
        codepoint.between?(0xff00, 0xff60) ||
        codepoint.between?(0xffe0, 0xffe6) ||
        codepoint.between?(0x1f300, 0x1faff) ||
        codepoint.between?(0x20000, 0x3fffd)
    end

    def slice(text, start, length)
      return '' if length <= 0

      skipped = 0
      result = +''
      used = 0
      text.each_char do |char|
        char_width = width(char)
        if skipped + char_width <= start
          skipped += char_width
          next
        end
        break if used + char_width > length

        result << char
        used += char_width
      end
      result
    end

    def wrap(text, width)
      return [''] if width < 1

      text.to_s.split("\n", -1).flat_map do |line|
        rows = [+'']
        remaining = width
        line.scan(/\S+\s*|\s+/) do |word|
          word.each_char do |char|
            if width(char) > remaining
              rows << +'' unless rows.last.empty?
              remaining = width
            end
            rows.last << char
            remaining -= width(char)
          end
        end
        rows
      end
    end
  end

  # Markdown for the transcript. Fenced code blocks are marked as code (so the
  # caller can colour and indent them), headings lose their hashes and are
  # marked for emphasis, and inline `code`, **bold** and *italic* become styled
  # segments instead of literal markers. A fence tagged ruby (or rb) is
  # tokenised like eval code; every other fence stays plain code. Every line
  # comes back as a Row, so a single line can mix styles.
  module Markdown
    module_function

    FENCE = '```'
    # Fence languages RubyHighlight understands. Anything else (json, sh, an
    # untagged fence) keeps the plain code colour rather than being guessed as
    # Ruby, where "if"/"then"/"end" would light up in the wrong language.
    RUBY_FENCES = %w[ruby rb].freeze
    HEADING = /\A\#{1,6}\s+/
    # Inline spans, tried left to right: `code`, **bold**, *italic*. A marker
    # only counts when non-space text follows and precedes it, so "2 * 3 * 4"
    # stays literal. Underscore emphasis is deliberately unsupported: it would
    # mangle snake_case identifiers in a coding transcript.
    INLINE = /`([^`\n]+)`|\*\*(?=\S)(.+?)(?<=\S)\*\*|\*(?=\S)(.+?)(?<=\S)\*/

    # One wrapped display row: [text, style] segments that together fit the
    # requested width. Styles are nil for prose, otherwise :code, :heading,
    # :bold, :italic or :inline_code; the UI maps them to colours and
    # attributes.
    class Row
      attr_reader :segments

      def initialize(segments = [])
        @segments = segments
        @width = segments.sum { |text, _style| Text.width(text) }
      end

      # Appends text in one style, merging into the previous segment when the
      # style matches so a row stays a short list of runs.
      def concat(text, style = nil)
        return self if text.nil? || text.empty?

        last = @segments.last
        if last && last[1] == style
          last[0] << text
        else
          @segments << [+text, style]
        end
        @width += Text.width(text)
        self
      end

      # Returns a copy with `prefix` in front, used for the transcript indent.
      def indented(prefix, style = nil)
        Row.new([[+prefix, style], *@segments])
      end

      # Plain text of the row without styling: used by tests and by search.
      def text = @segments.map(&:first).join

      def width = @width
      def empty? = @width.zero?
    end

    # Turns text into rows, one per display line. Rows inside a ruby fence carry
    # token styles; rows inside any other fence carry the plain code style.
    def lines(text, width)
      rows = []
      fenced = false
      ruby = false
      text.to_s.split("\n", -1).each do |line|
        if line.strip.start_with?(FENCE)
          fenced = !fenced
          ruby = fenced && ruby_fence?(line.strip)
          next
        end
        rows.concat(fenced ? fenced_lines(line, width, ruby) : plain_lines(line, width))
      end
      rows
    end

    # True when a fence marker names a language RubyHighlight can colour, e.g.
    # "```ruby" or "```rb title=x"; an untagged "```" is not one.
    def ruby_fence?(marker)
      RUBY_FENCES.include?(marker[FENCE.length..].to_s.split.first.to_s.downcase)
    end

    # One line inside a fence: Ruby tokens when the fence named Ruby, plain code
    # otherwise. Both indent the same way, so widths and wraps do not move.
    def fenced_lines(line, width, ruby)
      ruby ? ruby_rows(line, width) : code_rows(line, width)
    end

    # Every line marked as code: used for tool calls, which are code by nature.
    def code_lines(text, width)
      text.to_s.split("\n", -1).flat_map { |line| code_rows(line, width) }
    end

    def plain_lines(line, width)
      heading = line.match?(HEADING)
      fill(inline_chars(heading ? line.sub(HEADING, '') : line, heading ? :heading : nil), width)
    end

    # Like code_lines, but Ruby tokens keep their own style so eval code reads
    # like source. Row widths, indent and line breaks are identical to
    # code_lines, so highlighting never moves a wrap or a search row.
    def ruby_lines(text, width)
      text.to_s.split("\n", -1).flat_map { |line| ruby_rows(line, width) }
    end

    def ruby_rows(line, width)
      inner = [width - 2, 1].max
      fill(RubyHighlight.chars(line), inner).map { |row| row.indented('  ', :code) }
    end

    # Two extra spaces keep code visibly apart from prose, so wrap inside them.
    def code_rows(line, width)
      inner = [width - 2, 1].max
      fill(line.each_char.map { |char| [char, :code] }, inner).map { |row| row.indented('  ', :code) }
    end

    # A read_source result opens with "# path (lines a-b)" and then prints
    # "%4d | code" rows. That text is source, not prose, so it must not go
    # through the inline rules: markdown would read *args and `backticks` in the
    # code as emphasis and delete the markers.
    SOURCE_HEADER = /\A# (\S.*?) \(lines \d+-\d+\)\z/
    GUTTER = /\A( *\d+ \| )(.*)\z/

    # True when the text looks like a read_source result, whose first line names
    # the file and the line range the rows came from.
    def source?(text)
      SOURCE_HEADER.match?(text.to_s.split("\n", 2).first.to_s)
    end

    # Rows for a read_source result. The header reads as a heading over the code,
    # and each row keeps its gutter in the plain code colour so line numbers are
    # never mistaken for numeric literals; the code after the gutter is tokenised
    # for the language the file name names. Indent and wrap match code_rows, so
    # search and scrolling see the usual rows.
    def source_lines(text, width)
      lines = text.to_s.split("\n", -1)
      path = lines.first.to_s[SOURCE_HEADER, 1]
      language = Syntax.for_path(path)
      rows = []
      lines.each_with_index do |line, index|
        if index.zero? && path
          chars = []
          add_chars(chars, path, :heading)
          rows.concat(fill(chars, width))
        else
          rows.concat(source_rows(line, width, language))
        end
      end
      rows
    end

    # One gutter-numbered line: gutter in code colour, code in its token styles.
    # A language without rules keeps a uniform code colour rather than guessing.
    def source_rows(line, width, language)
      gutter, code = split_gutter(line)
      chars = []
      add_chars(chars, gutter, :code)
      tokens = Syntax.chars(code, language)
      tokens ? chars.concat(tokens) : add_chars(chars, code, :code)
      inner = [width - 2, 1].max
      fill(chars, inner).map { |row| row.indented('  ', :code) }
    end

    # " 123 | code" split into its gutter and the untouched source line. A line
    # shorter than the header promises (a truncated tail) keeps an empty gutter.
    def split_gutter(line)
      match = GUTTER.match(line.to_s)
      match ? [match[1], match[2]] : ['', line.to_s]
    end

    # Markdown files shown as source keep every character, markers included: this
    # is the file, not a rendering of it. Only headings are picked out, because
    # they are the one piece of structure worth seeing at a glance.
    def markdown_chars(line)
      heading = line.to_s.match?(HEADING)
      line.to_s.each_char.map { |char| [char, heading ? :heading : nil] }
    end

    # Splits a line into [char, style] pairs with the inline markers removed.
    def inline_chars(line, base = nil)
      chars = []
      source = line.to_s
      pos = 0
      while (match = INLINE.match(source, pos))
        add_chars(chars, source[pos...match.begin(0)], base)
        style, content = inline_span(match)
        add_chars(chars, content, style)
        pos = match.end(0)
      end
      add_chars(chars, source[pos..], base)
      chars
    end

    # Which inline style a match carries, and the text inside its markers.
    def inline_span(match)
      return [:inline_code, match[1]] if match[1]
      return [:bold, match[2]] if match[2]

      [:italic, match[3]]
    end

    def add_chars(chars, text, style)
      text.to_s.each_char { |char| chars << [char, style] }
    end

    # Wraps [char, style] pairs into rows, breaking exactly where Text.wrap
    # does so styling never moves the line breaks.
    def fill(chars, width)
      return [Row.new] if width < 1

      rows = [Row.new]
      chars.each do |char, style|
        rows << Row.new if !rows.last.empty? && Text.width(char) > width - rows.last.width
        rows.last.concat(char, style)
      end
      rows
    end
  end

  # Line-oriented Ruby highlighter for eval code. It is a display aid, not a
  # parser: each line is tokenised on its own and anything unrecognised stays
  # plain, so a half-typed or multi-line construct costs colour, never text.
  #
  # Alternatives are tried left to right at the earliest position, which is what
  # keeps the rules honest: a string swallows the "#" and ":sym" inside it, "::"
  # is refused as a symbol so Foo::Bar keeps its constant, and a comment runs to
  # the end of the line.
  module RubyHighlight
    module_function

    KEYWORDS = %w[__FILE__ __LINE__ __method__ alias and begin break case class def
                  defined? do else elsif end ensure false for if in module next nil
                  not or redo rescue retry return self super then true undef unless
                  until when while yield].freeze
    # Built once here so the token pattern below stays readable.
    KEYWORD = /\b(?:#{KEYWORDS.map { |word| Regexp.escape(word) }.join('|')})\b/

    # One alternative per token class. The "x" flag and escaped brackets keep
    # the brackets of a %w[] literal from ending the pattern.
    TOKEN = %r~
        (?<comment>\#[^\n]*)
      | (?<string>"(?:[^"\\]|\\.)*"?|'(?:[^'\\]|\\.)*'?)
      | (?<method>(?<=\bdef\s)[a-z_]\w*[?!=]?)
      | (?<symbol>(?<!:):[A-Za-z_]\w*[?!=]?)
      | (?<number>\b\d[\d_]*(?:\.\d[\d_]*)?\b)
      | (?<constant>\b[A-Z]\w*[?!]?)
      | (?<keyword>#{KEYWORD.source})
    ~x

    # Group name to the style the UI knows. Every group in TOKEN is named here,
    # so a new token class cannot silently arrive without a colour.
    STYLE_FOR = {
      'comment' => :comment, 'string' => :string, 'method' => :method,
      'symbol' => :symbol, 'number' => :number, 'constant' => :constant,
      'keyword' => :keyword
    }.freeze

    # [char, style] pairs for one line, in order, with no character dropped.
    def chars(line)
      Tokenizer.chars(line, TOKEN, STYLE_FOR)
    end
  end

  # Drives the line tokenisers: walks a pattern whose alternatives are named
  # after token classes and returns [char, style] pairs in order. Unmatched text
  # keeps a nil style, and no character is dropped, so a mis-tokenised line still
  # renders exactly as written.
  module Tokenizer
    module_function

    def chars(line, pattern, styles)
      out = []
      source = line.to_s
      pos = 0
      while (match = pattern.match(source, pos))
        push(out, source[pos...match.begin(0)], nil)
        push(out, match[0], styles[token_name(match)])
        pos = match.end(0)
      end
      push(out, source[pos..], nil)
      out
    end

    # The named group that matched; every alternative is named, so this only
    # returns nil for a pattern change that forgets to name one.
    def token_name(match)
      match.names.find { |name| match[name] }
    end

    def push(out, text, style)
      text.to_s.each_char { |char| out << [char, style] }
    end
  end

  # Generic tokeniser for the languages that have no rules of their own: read
  # files of any type still get strings, numbers, comments and keywords. A
  # language is a SPECS entry (comment marker, keyword list, optional keys), so
  # adding one is a table entry rather than new code.
  #
  # Alternatives are ordered so a string starting before a comment marker wins
  # over it, and keywords only match whole words. Like RubyHighlight this is a
  # display aid: lines are tokenised one at a time, so half a construct costs
  # colour, never text.
  module CodeHighlight
    module_function

    # A backslash is spelled \x5c here so the pattern needs no doubled escape.
    # Unterminated quotes are allowed: a line of a multi-line literal costs
    # colour, never text.
    STRING = /"(?:[^"\x5c]|\x5c.)*"?|'(?:[^'\x5c]|\x5c.)*'?/
    NUMBER = /\b\d[\d_]*(?:\.\d[\d_]*)?\b/
    COMMENT = { hash: /\#[^\n]*/, slash: /\/\/[^\n]*/ }.freeze

    # Keyword lists are deliberately short: a missing word costs no colour,
    # while a wrong one would light up in the wrong language. c_like pools the
    # C family (C, Go, Rust, Java, Swift) because their overlap is all a display
    # aid needs.
    SPECS = {
      json: { keywords: %w[true false null] },
      yaml: { comment: :hash, keywords: %w[true false null yes no on off], keys: true },
      shell: { comment: :hash,
               keywords: %w[if then else elif fi for while until do done case esac in function
                            return local export readonly echo exit set source break continue] },
      python: { comment: :hash,
                keywords: %w[def class return if elif else for while import from as with try
                             except finally raise lambda yield assert pass break continue None
                             True False and or not in is del global nonlocal self] },
      javascript: { comment: :slash,
                    keywords: %w[const let var function return if else for while do break
                                 continue class extends new this import export from default async
                                 await try catch finally throw typeof instanceof null true false
                                 undefined of in delete void] },
      c_like: { comment: :slash,
                keywords: %w[if else for while do return switch case break continue struct enum
                             class interface public private protected static const final void int
                             char bool fn let mut pub use impl trait match loop type nil null true
                             false func package import var] }
    }.freeze

    # YAML keys carry the method colour: a name at the start of a line is the
    # closest thing YAML has to an identifier.
    STYLE_FOR = { 'comment' => :comment, 'key' => :method, 'string' => :string,
                  'number' => :number, 'keyword' => :keyword }.freeze

    # One compiled pattern per language, built on first use: the keyword
    # alternations are long and most sessions never read these files.
    def patterns
      @patterns ||= SPECS.to_h { |language, spec| [language, build(spec)] }
    end

    # [char, style] pairs for one line, or nil when the language has no spec.
    def chars(line, language)
      pattern = patterns[language]
      pattern ? Tokenizer.chars(line, pattern, STYLE_FOR) : nil
    end

    def build(spec)
      parts = []
      parts << "(?<comment>#{COMMENT.fetch(spec[:comment]).source})" if spec[:comment]
      parts << '(?<key>^[ \t-]*[\w.\/-]+(?=[ \t]*:))' if spec[:keys]
      parts << "(?<string>#{STRING.source})"
      parts << "(?<number>#{NUMBER.source})"
      # Word-boundaries are written as lookarounds: a "\b" inside this
      # double-quoted string would be a backspace character, not a boundary.
      parts << "(?<keyword>(?<!\w)(?:#{keyword_source(spec[:keywords])})(?!\w))"
      Regexp.new(parts.join('|'))
    end

    def keyword_source(words)
      words.map { |word| Regexp.escape(word) }.join('|')
    end
  end

  # Chooses the highlighter for a file the transcript is showing, by file name
  # and extension. Only languages with rules are mapped: an unknown type stays
  # plain code, because guessing would colour words in the wrong language, which
  # reads worse than no colour at all.
  module Syntax
    module_function

    # Names win over extensions: Gemfile and Rakefile have none, and the bin
    # script is the only clue that bin/rubycog is Ruby.
    BY_NAME = { 'Gemfile' => :ruby, 'Gemfile.lock' => :yaml, 'Rakefile' => :ruby,
                'Guardfile' => :ruby, 'rubycog' => :ruby, '.rubocop.yml' => :yaml }.freeze

    BY_EXTENSION = {
      '.rb' => :ruby, '.rake' => :ruby, '.gemspec' => :ruby, '.ru' => :ruby,
      '.json' => :json, '.yml' => :yaml, '.yaml' => :yaml, '.toml' => :yaml,
      '.sh' => :shell, '.bash' => :shell, '.zsh' => :shell,
      '.py' => :python, '.js' => :javascript, '.mjs' => :javascript,
      '.ts' => :javascript, '.jsx' => :javascript, '.tsx' => :javascript,
      '.c' => :c_like, '.h' => :c_like, '.cc' => :c_like, '.cpp' => :c_like,
      '.go' => :c_like, '.rs' => :c_like, '.java' => :c_like, '.swift' => :c_like,
      '.kt' => :c_like, '.cs' => :c_like, '.md' => :markdown, '.markdown' => :markdown
    }.freeze

    # Language id for a path, or nil when no rules fit it.
    def for_path(path)
      return nil if path.nil? || path.to_s.empty?

      name = File.basename(path.to_s)
      BY_NAME[name] || BY_EXTENSION[File.extname(name).downcase]
    end

    # [char, style] pairs for one line of `language`, or nil when the language
    # has no rules and the caller should keep its plain code colour.
    def chars(line, language)
      case language
      when nil then nil
      when :ruby then RubyHighlight.chars(line)
      when :markdown then Markdown.markdown_chars(line)
      else CodeHighlight.chars(line, language)
      end
    end
  end
end
