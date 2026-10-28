# frozen_string_literal: true

# ECMA-262 (JavaScript) regular expressions for Ruby, with the grammar and the answers of RegExp, every flag, backed by
# the corvus-regex-ecma262 Rust crate.
#
#   date = CorvusRegexEcma262::Regex.new('(?<year>\d{4})-(?<month>\d{2})', "gu")
#   date.match?("due 2026-10")                       # => true
#   date.match("due 2026-10")[:year]                 # => "2026"
#   date.each_match("2026-10, 2027-01").map(&:to_s)  # => ["2026-10", "2027-01"]
#   date.replace("2026-10, 2027-01", "$<month>/$1")  # => "10/2026, 01/2027"
#
# A String is matched as it is held: UTF-8 (or US-ASCII, or binary holding UTF-8) as UTF-8, with positions in
# characters as Ruby counts them and byte positions beside them; UTF-16LE as UTF-16, with positions in code units.
# Without the u or v flag a pattern is matched by UTF-16 code unit, so a match can take half of a character beyond the
# Basic Multilingual Plane: over UTF-8 its text holds that half as U+FFFD, and its start and end in characters are the
# whole character's.
require_relative "corvus_regex_ecma262/version"

begin
  RUBY_VERSION =~ /(\d+\.\d+)/
  require_relative "corvus_regex_ecma262/#{Regexp.last_match(1)}/corvus_regex_ecma262"
rescue LoadError
  require_relative "corvus_regex_ecma262/corvus_regex_ecma262"
end

module CorvusRegexEcma262
  UTF16LE = Encoding::UTF_16LE

  # The versions of Unicode the gem carries, each a set of tables a pattern can be read with (unicode_version:).
  UNICODE_VERSIONS = [13, 17, 18].freeze
  # The version a pattern is read with by default: the version of the V8 the answers are held to.
  DEFAULT_UNICODE_VERSION = Native.default_unicode_version
  # The newest version the gem carries, which unicode_version: :latest stands for.
  LATEST_UNICODE_VERSION = Native.latest_unicode_version

  # The editions of ECMA-262 whose grammar a pattern can be read with (edition:), as the extension numbers them.
  EDITIONS = { current: 0, es2020: 1 }.freeze

  # A compiled ECMA-262 regular expression, as new RegExp(pattern, flags) compiles it. It is immutable, and may be
  # used from any number of threads.
  class Regex
    attr_reader :names

    # Compiles a pattern with the flags new RegExp(pattern, flags) takes, any of dgimsuvy. Raises InvalidPatternError,
    # InvalidFlagsError or PatternTooLargeError (each an Error). timeout: is the time in seconds each match may take
    # before it is abandoned with MatchLimitError (0 for none); nil takes CorvusRegexEcma262.default_timeout, which is
    # none unless set. A timeout also caps the backtracking memory of a match; without one a match has no limit of time
    # or of memory, so give a pattern or a text from outside one.
    #
    # edition: is the grammar the pattern is read with: :current (today's, the default) or :es2020, the grammar of
    # ECMAScript 2020, which JSON Schema 2020-12 names. It refuses what later editions added, and nothing else: the d
    # and v flags (InvalidFlagsError), modifier groups such as (?i:...), a group name used by two groups, and a property
    # name or value that is not in that edition's tables (InvalidPatternError). unicode_version: is the version of
    # Unicode whose tables the pattern is read with: nil (the default, DEFAULT_UNICODE_VERSION), 13, 17, 18 or :latest
    # (LATEST_UNICODE_VERSION). Each is independent of the other; both are settled here, and cost a match nothing.
    def initialize(pattern, flags = "", timeout: nil, edition: :current, unicode_version: nil)
      @native = Native::Regex.new(CorvusRegexEcma262.utf8(pattern), flags.to_s, timeout&.to_f,
                                  CorvusRegexEcma262.edition_code(edition),
                                  CorvusRegexEcma262.unicode_version_code(unicode_version))
      @names = @native.names.freeze
      freeze
    end

    # Whether a pattern is valid with the flags, in the edition and the version of Unicode, without compiling it.
    def self.valid?(pattern, flags = "", edition: :current, unicode_version: nil)
      Native::Regex.valid?(CorvusRegexEcma262.utf8(pattern), flags.to_s, CorvusRegexEcma262.edition_code(edition),
                           CorvusRegexEcma262.unicode_version_code(unicode_version))
    end

    # The edition whose grammar the pattern was read with: :current or :es2020.
    def edition = EDITIONS.key(@native.edition)

    # The version of Unicode whose tables the pattern was read with, resolved: 13, 17 or 18.
    def unicode_version = @native.unicode_version

    # The pattern as it was given, as UTF-8.
    def source = @native.source

    # The flags as RegExp.prototype.flags writes them, in the order dgimsuvy.
    def flags = @native.flags

    # The time in seconds each match may take before it is abandoned with MatchLimitError, or nil for no limit.
    def timeout = @native.timeout

    # The number of capturing groups.
    def group_count = @native.group_count

    # Whether the pattern matches at or after pos (at pos alone with the y flag), as RegExp.prototype.test with
    # lastIndex set to pos. A match that reaches the pattern's timeout raises MatchLimitError; timeout: (seconds) takes
    # its place for this match (0 for none).
    def match?(string, pos = 0, timeout: nil)
      @native.test(string, CorvusRegexEcma262.unit_of(string, pos), timeout&.to_f)
    end

    # The first match at or after pos, as exec finds it with lastIndex set to pos: a Match, or nil. With a block, the
    # block's result for the match, or nil. A match that reaches the pattern's timeout raises MatchLimitError;
    # timeout: (seconds) takes its place for this match (0 for none).
    def match(string, pos = 0, timeout: nil)
      groups = @native.exec(string, CorvusRegexEcma262.unit_of(string, pos), timeout&.to_f)
      return nil unless groups

      m = Match.new(self, string, groups, Positions.new(string))
      block_given? ? yield(m) : m
    end

    # Every match of a global search of the string, as matchAll makes one: yields each Match, or returns an
    # Enumerator. After an empty match the search goes on one character later, and with the y flag each match must
    # start where the one before ended. A match that reaches the pattern's timeout raises MatchLimitError, and ends the
    # search.
    def each_match(string)
      return enum_for(:each_match, string) unless block_given?

      string = CorvusRegexEcma262.snapshot(string)
      positions = Positions.new(string)
      @native.each(string) { |groups| yield Match.new(self, string, groups, positions) }
      self
    end

    # The number of matches of a global search, without making them.
    def match_count(string) = @native.count(string)

    # The string with the first match replaced, or every match with the g flag, as String.prototype.replace replaces
    # them. The replacement is a template ($& the match, $` the text before it, $' the text after it, $1 to $99 a
    # group, $<name> a named group, $$ a dollar sign), or the block's result for each Match.
    def replace(string, replacement = nil, &block)
      substitute(string, replacement, @native.global?, &block)
    end

    # The string with every match replaced, whether or not the g flag is set (String.prototype.replaceAll).
    def replace_all(string, replacement = nil, &block)
      substitute(string, replacement, true, &block)
    end

    # The string split around the matches, as String.prototype.split(separator, limit) splits it: what each group
    # captured is spliced in after the piece before it (nil for a group that did not take part), an empty match at
    # the start or the end splits nothing, and there are at most limit pieces.
    def split(string, limit = nil)
      @native.split(string, limit).map { |piece| piece&.force_encoding(CorvusRegexEcma262.result_encoding(string)) }
    end

    def inspect = "#<CorvusRegexEcma262::Regex /#{source}/#{flags}>"
    alias to_s inspect

    def ==(other) = other.is_a?(Regex) && other.source == source && other.flags == flags
    alias eql? ==
    def hash = [source, flags].hash

    private

    def substitute(string, replacement, all)
      unless block_given?
        raise ArgumentError, "a replacement or a block" if replacement.nil?

        template = string.encoding == UTF16LE ? replacement.encode(UTF16LE) : CorvusRegexEcma262.utf8(replacement)
        return @native.replace(string, template, all).force_encoding(CorvusRegexEcma262.result_encoding(string))
      end
      raise ArgumentError, "a replacement or a block, not both" unless replacement.nil?

      string = CorvusRegexEcma262.snapshot(string)
      out = +""
      out.force_encoding(CorvusRegexEcma262.result_encoding(string))
      last = 0
      unit = string.encoding == UTF16LE ? 2 : 1
      positions = Positions.new(string)
      @native.each(string) do |groups|
        m = Match.new(self, string, groups, positions)
        out << string.byteslice(last * unit, (groups[0] - last) * unit) << yield(m).to_s
        last = groups[1]
        break unless all
      end
      out << string.byteslice(last * unit, string.bytesize - last * unit)
    end
  end

  # Where a match and its groups are, read as a MatchData is: by number, by name (String or Symbol), with begin, end
  # and offset in characters (in code units for a UTF-16LE string), and byte_begin, byte_end and byteoffset in bytes.
  class Match
    attr_reader :string, :regexp

    def initialize(regexp, string, groups, positions)
      @regexp = regexp
      @string = string
      @groups = groups
      @positions = positions
    end

    # The number of groups, the whole match among them.
    def size = @regexp.group_count + 1
    alias length size

    def names = @regexp.names

    # The text of a group, by number, name or Symbol: nil when it did not take part.
    def [](group)
      s, e = span(group)
      return nil if s.negative?

      text(s, e)
    end

    # The start of the group in characters (code units for UTF-16LE), or nil when it did not take part.
    def begin(group = 0)
      s, = span(group)
      s.negative? ? nil : @positions.char(s, false)
    end

    # The end of the group in characters (code units for UTF-16LE), or nil when it did not take part.
    def end(group = 0)
      _, e = span(group)
      e.negative? ? nil : @positions.char(e, true)
    end

    # [begin, end] of the group, or [nil, nil] when it did not take part.
    def offset(group = 0) = [self.begin(group), self.end(group)]

    def byte_begin(group = 0)
      s, = span(group)
      s.negative? ? nil : s * unit
    end

    def byte_end(group = 0)
      _, e = span(group)
      e.negative? ? nil : e * unit
    end

    def byteoffset(group = 0) = [byte_begin(group), byte_end(group)]

    # The text of every capturing group, nil for one that did not take part.
    def captures = (1...size).map { |g| self[g] }

    # The text of each name's group.
    def named_captures = names.to_h { |n| [n, self[n]] }

    def to_a = (0...size).map { |g| self[g] }
    def values_at(*groups) = groups.map { |g| self[g] }
    def to_s = self[0]
    def pre_match = text(0, @groups[0])
    def post_match = @string.byteslice(@groups[1] * unit, @string.bytesize - (@groups[1] * unit))

    def inspect = "#<CorvusRegexEcma262::Match #{to_s.inspect} #{offset.inspect}>"

    private

    def unit = @string.encoding == UTF16LE ? 2 : 1

    # [start, end] of a group in engine positions (-1 for one that did not take part).
    def span(group)
      i = case group
          when Integer
            raise IndexError, "index #{group} out of matches" if group.negative? || group >= size

            group
          when String, Symbol
            k = names.index(group.to_s)
            raise IndexError, "undefined group name reference: #{group}" unless k

            size + k
          else
            raise TypeError, "a group is an Integer, a String or a Symbol"
          end
      [@groups[2 * i], @groups[(2 * i) + 1]]
    end

    def text(s, e)
      piece = @string.byteslice(s * unit, (e - s) * unit)
      # A half of a character (without u or v, over UTF-8) is no UTF-8: written as U+FFFD, as the crate writes it.
      piece.valid_encoding? ? piece : piece.scrub("�")
    end
  end

  # Byte positions to character positions, going on from where it was last asked, since a search asks in order.
  class Positions
    def initialize(string)
      @string = string
      @identity = string.encoding == UTF16LE || string.ascii_only?
      @byte = 0
      @char = 0
    end

    # The character index of a byte position; a position inside a character (between the halves of one beyond the
    # Basic Multilingual Plane) is its start, or (for an end) past it.
    def char(byte, at_end)
      return byte if @identity

      @byte = @char = 0 if byte < @byte
      inside = byte < @string.bytesize && (@string.getbyte(byte) & 0xC0) == 0x80
      target = byte
      target -= 1 while inside && target.positive? && (@string.getbyte(target) & 0xC0) == 0x80
      @char += @string.byteslice(@byte, target - @byte).length
      @byte = target
      inside && at_end ? @char + 1 : @char
    end
  end

  class << self
    # Compiles a pattern: Regex.new(pattern, flags, timeout:, edition:, unicode_version:).
    def compile(pattern, flags = "", timeout: nil, edition: :current, unicode_version: nil)
      Regex.new(pattern, flags, timeout: timeout, edition: edition, unicode_version: unicode_version)
    end

    # The timeout in seconds of every Regex made without one of its own, or nil for no limit (the default).
    def default_timeout = Native.default_timeout

    # Sets the timeout of every Regex made from now on without one of its own: seconds, or nil (or 0) for no limit. It
    # is the process-wide default of .NET's REGEX_DEFAULT_MATCH_TIMEOUT; a program that matches patterns or texts from
    # outside should set one when it starts. A Regex already made keeps its own.
    def default_timeout=(seconds)
      Native.default_timeout = seconds&.to_f
    end

    # Whether a pattern is valid with the flags, in the edition and the version of Unicode, without compiling it.
    def valid?(pattern, flags = "", edition: :current, unicode_version: nil)
      Regex.valid?(pattern, flags, edition: edition, unicode_version: unicode_version)
    end

    # The version of the crate the extension was built with.
    def crate_version = Native.crate_version

    # @api private: the extension's number for an edition.
    def edition_code(edition)
      EDITIONS.fetch(edition) { raise ArgumentError, "edition must be :current or :es2020" }
    end

    # @api private: the extension's number for a version of Unicode: 0 for the default, u32::MAX for the latest.
    def unicode_version_code(version)
      case version
      when nil then 0
      when :latest then 0xFFFF_FFFF
      when Integer
        return version if UNICODE_VERSIONS.include?(version)

        raise ArgumentError, "unicode_version must be nil, 13, 17, 18 or :latest"
      else raise ArgumentError, "unicode_version must be nil, 13, 17, 18 or :latest"
      end
    end

    # @api private
    def utf8(s)
      s = s.to_s
      return s if s.encoding == Encoding::UTF_8 || (s.encoding == Encoding::US_ASCII && s.ascii_only?)

      # A lone surrogate (in a UTF-16 pattern) is read as U+FFFD, as the crate's UTF-8 patterns have none.
      s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "�")
    end

    # @api private: the string as a search that runs a block walks it, frozen, so that it cannot change under the
    # search and any number of searches may walk it at once. A string that is not frozen is copied as Ruby copies a
    # String, sharing its bytes until either is changed.
    def snapshot(string) = string.frozen? ? string : string.dup.freeze

    # @api private
    def result_encoding(string) = string.encoding == UTF16LE ? UTF16LE : Encoding::UTF_8

    # @api private: the engine position of a character position.
    def unit_of(string, pos)
      raise ArgumentError, "pos must not be negative" if pos.negative?
      return pos if string.encoding == UTF16LE || string.ascii_only? || pos.zero?
      # Past the end, as lastIndex past a string's length: no match.
      return string.bytesize + 1 if pos > string.length

      string[0, pos].bytesize
    end
  end
end
