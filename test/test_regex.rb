# frozen_string_literal: true

# The gem's tests: each member over UTF-8 and UTF-16LE strings, against the answers V8 gives.
require "minitest/autorun"
require "corvus_regex_ecma262"

class TestRegex < Minitest::Test
  R = CorvusRegexEcma262

  def u16(s) = s.encode(Encoding::UTF_16LE)

  def test_compiling
    r = R::Regex.new('(?<year>\d{4})-(?<month>\d{2})', "gu")
    assert_equal '(?<year>\d{4})-(?<month>\d{2})', r.source
    assert_equal "gu", r.flags
    assert_equal 2, r.group_count
    assert_equal %w[year month], r.names
    # The flags come back in the order RegExp.prototype.flags writes them.
    assert_equal "giy", R.compile("a", "yig").flags
    assert r.frozen?
    assert_equal R.compile("a", "g"), R.compile("a", "g")
  end

  def test_errors_say_why
    assert_raises(R::InvalidPatternError) { R.compile("(") }
    assert_raises(R::InvalidPatternError) { R.compile('\p{Nope}', "u") }
    assert_raises(R::InvalidFlagsError) { R.compile("a", "uv") }
    assert_raises(R::InvalidFlagsError) { R.compile("a", "q") }
    assert_raises(R::PatternTooLargeError) { R.compile(("(" * 1001) + (")" * 1001)) }
    assert_kind_of R::Error, R::MatchLimitError.new
    assert R::Error < StandardError
  end

  def test_valid
    assert R.valid?("a+", "u")
    refute R.valid?("a{2,1}", "u")
    # Annex B reads {2,1 as text without u.
    assert R.valid?("a{2,1", "")
    refute R.valid?("a{2,1", "u")
  end

  def test_match_and_match?
    r = R.compile("o+")
    assert r.match?("foo")
    refute r.match?("bar")
    m = r.match("a foo, a boo", 3)
    assert_equal [3, 5], m.offset
    assert_equal "oo", m.to_s
    assert_equal [10, 12], r.match("a foo, a boo", 5).offset
    assert_nil r.match("a foo", 5)
    assert_nil r.match("a foo", 99)
    assert_equal "oo", r.match("foo") { |x| x[0] }
    # The y flag: a match starts where the search starts.
    sticky = R.compile("o", "y")
    assert sticky.match?("foo", 1)
    refute sticky.match?("foo", 0)
  end

  def test_positions_in_characters_and_bytes
    m = R.compile("ok").match("café ok")
    assert_equal [5, 7], m.offset
    assert_equal [6, 8], m.byteoffset
    assert_equal [3, 4], R.compile("é").match("café", 1).offset
    assert_equal "a", R.compile("a").match("ééa").to_s
  end

  def test_utf16le_strings
    r = R.compile("o+")
    m = r.match(u16("a foo"))
    assert_equal [3, 5], m.offset
    assert_equal u16("oo"), m[0]
    assert_equal Encoding::UTF_16LE, m[0].encoding
    # A lone surrogate in a UTF-16LE string is a unit of its own.
    lone = "a".encode("UTF-16LE") + [0xD800].pack("v").force_encoding("UTF-16LE") + "b".encode("UTF-16LE")
    assert R.compile("^...$").match?(lone)
    assert R.compile("^...$", "u").match?(lone)
    assert_equal [1, 2], R.compile('\ud800').match(lone).offset
    # A pair is one code point with u, two units without.
    assert R.compile("^..$").match?(u16("😀"))
    assert R.compile("^.$", "u").match?(u16("😀"))
  end

  def test_half_characters_without_u
    m = R.compile("^.").match("😀x")
    assert_equal "�", m.to_s
    assert_equal [0, 1], m.offset
    assert_equal [0, 2], m.byteoffset
    assert_equal "😀", R.compile("^.", "u").match("😀x").to_s
  end

  def test_groups
    r = R.compile('(?<year>\d{4})-(?<month>\d{2})(-(\d{2}))?', "u")
    m = r.match("due 2026-10, then")
    assert_equal "2026-10", m[0]
    assert_equal "2026", m[:year]
    assert_equal "10", m["month"]
    assert_nil m[3]
    assert_equal ["2026", "10", nil, nil], m.captures
    assert_equal({ "year" => "2026", "month" => "10" }, m.named_captures)
    assert_equal [9, 11], m.offset(:month)
    assert_nil m.begin(3)
    assert_equal "due ", m.pre_match
    assert_equal ", then", m.post_match
    assert_equal 5, m.size
    assert_same r, m.regexp
    assert_raises(IndexError) { m[9] }
    assert_raises(IndexError) { m[:nope] }
    # Two groups in separate alternatives may share a name: the one that took part is the name's.
    assert_equal "b", R.compile("(?<d>a)|(?<d>b)", "u").match("b")[:d]
  end

  def test_each_match
    r = R.compile('\d+', "g")
    assert_equal %w[1 22 333 4444], r.each_match("1 22 333 4444").map(&:to_s)
    assert_equal 1000, R.compile("a", "g").each_match("a " * 1000).count
    assert_equal 1000, R.compile("a", "g").match_count("a " * 1000)
    # After an empty match the search goes on one code point with u, one code unit without.
    assert_equal 2, R.compile("", "gu").each_match("😀").count
    assert_equal 3, R.compile("", "g").each_match(u16("😀")).count
    assert_equal [[0, 0], [2, 2], [4, 4], [5, 5]], R.compile("", "g").each_match("😀,").map(&:byteoffset)
    # The y flag: each match starts where the one before ended.
    assert_equal 2, R.compile("a", "gy").each_match("aab").count
    assert_equal 0, R.compile("a", "gy").each_match("baa").count
    # Positions over non-ASCII text, in order.
    assert_equal [[0, 1], [4, 5], [8, 9]], R.compile("é", "g").each_match("é a é b é").map(&:offset)
    # A frozen string is searched as it is (Ruby 4.0 refuses to lock one against change, as a search does a string
    # that is not frozen).
    assert_equal 3, R.compile("a", "g").each_match("aaa".dup.freeze).count
    assert_equal "bbb", R.compile("a", "g").replace("aaa".dup.freeze) { "b" }
    # A search walks the string as it was when the search began, whatever the block does to it, and searches of
    # one string may run inside one another.
    s = +"aaa"
    seen = []
    R.compile("a", "g").each_match(s) { |m| seen << m.begin(0); s << "a" }
    assert_equal [0, 1, 2], seen
    nested = 0
    R.compile("a", "g").each_match(s) { R.compile("a", "g").each_match(s) { nested += 1 } }
    assert_equal 36, nested
  end

  def test_replace
    date = R.compile('(?<y>\d{4})-(?<m>\d{2})', "g")
    assert_equal "10/2026, 01/2027", date.replace("2026-10, 2027-01", "$<m>/$1")
    first = R.compile('\d+')
    assert_equal "[1] 2 3", first.replace("1 2 3", "[$&]")
    assert_equal "[1] [2] [3]", first.replace_all("1 2 3", "[$&]")
    assert_equal "a<a|b|$>b", first.replace("a1b", "<$`|$'|$$>")
    assert_equal "2 4 6", first.replace_all("1 2 3") { |m| (m[0].to_i * 2).to_s }
    assert_equal "-a-b-", R.compile("", "g").replace_all("ab") { "-" }
    assert_equal u16("a<1>b"), first.replace(u16("a1b"), "<$&>")
    assert_raises(ArgumentError) { first.replace("a1") }
    # Over UTF-8 a half character is written as U+FFFD.
    assert_equal "x�", R.compile("^.").replace("😀", "x")
  end

  def test_split
    comma = R.compile('\s*(;)\s*')
    assert_equal %w[a ; b ; c], comma.split("a ; b;c")
    assert_equal %w[a ;], comma.split("a;b;c", 2)
    assert_equal ["a", nil, "b"], R.compile("(x)?,").split("a,b")
    assert_equal [u16("a"), u16(";"), u16("b")], comma.split(u16("a;b"))
  end

  def test_limits
    slow = R.compile('^(a+)+\1$')
    text = ("a" * 64) + "!"
    assert_raises(R::MatchLimitError) { slow.match?(text, timeout: 0.005) }
    assert_raises(R::MatchLimitError) { slow.match(text, timeout: 0.005) }
    # A pattern without a backreference takes time in proportion to its size times the text.
    refute R.compile('^(a+)+$').match?(text, timeout: 1)
  end

  def test_encodings
    assert_raises(ArgumentError) { R.compile("a").match("\xFF".b + "a") }
    assert R.compile("a").match?("a".b)
    assert_raises(EncodingError) { R.compile("a").match?("a".encode("UTF-32LE")) }
  end

  def test_threads
    r = R.compile('\w+', "g")
    text = "word " * 2000
    counts = Array.new(4) { Thread.new { (1..20).sum { r.each_match(text).count } } }.map(&:value)
    assert_equal [40_000] * 4, counts
  end
end
