# Getting started with Ruby

`corvus_regex_ecma262` is a gem whose patterns have the grammar and the answers of JavaScript's `RegExp`, held to V8's
answers on the ECMA-262 test data, over UTF-8 and UTF-16LE strings: the corvus-regex-ecma262 Rust crate, with native
builds for Linux (glibc and musl), macOS and Windows, x64 and arm64. A `Regex` is frozen, and used from any number of
threads.

## Install

```
gem install corvus_regex_ecma262
```

It needs Ruby 3.3 or later. With Bundler, add `gem "corvus_regex_ecma262"` to the Gemfile.

## Compile a pattern

`Regex.new` (or `CorvusRegexEcma262.compile`) takes a pattern and its flags as `new RegExp(pattern, flags)` takes them:
`d`, `g`, `i`, `m`, `s`, `u`, `v` and `y`. Without `u` or `v` a pattern is read by the Annex B grammar and matched by
UTF-16 code unit, as ECMA-262 reads it; with them, by code point. A pattern that is not valid raises
`InvalidPatternError` (or `InvalidFlagsError`, or `PatternTooLargeError`), each a `CorvusRegexEcma262::Error`.

```ruby
require "corvus_regex_ecma262"

date = CorvusRegexEcma262::Regex.new('(?<year>\d{4})-(?<month>\d{2})', "gu")
date.names                                         # => ["year", "month"]
date.group_count                                   # => 2

CorvusRegexEcma262.compile("a{2,1}", "u")          # raises CorvusRegexEcma262::InvalidPatternError
CorvusRegexEcma262.compile("a", "uv")              # raises CorvusRegexEcma262::InvalidFlagsError
CorvusRegexEcma262.valid?("(?<n>a)(?<n>b)", "u")   # => false
```

## Match

A match is a `CorvusRegexEcma262::Match`, read as a `MatchData` is: by number, by name or by Symbol, with positions in
characters as Ruby counts them, and in bytes beside them.

```ruby
require "corvus_regex_ecma262"

date = CorvusRegexEcma262::Regex.new('(?<year>\d{4})-(?<month>\d{2})', "gu")
text = "due 2026-10, then 2027-01"

date.match?(text)                                  # => true
m = date.match(text)
m.to_s                                             # => "2026-10"
m[:year]                                           # => "2026"
m[2]                                               # => "10"
m.offset                                           # => [4, 11]

# Every match of a global search, as matchAll makes it.
date.each_match(text).map(&:to_s)                  # => ["2026-10", "2027-01"]
date.match_count(text)                             # => 2

# replace replaces every match with the g flag, and the first without it, with every $ form of ECMA-262, or a block.
date.replace(text, "$<month>/$1")                  # => "due 10/2026, then 01/2027"
date.replace(text) { |each| each[:year] }          # => "due 2026, then 2027"

# split puts what the groups captured between the pieces; a group that did not take part is nil.
CorvusRegexEcma262.compile('\s*(;)\s*').split("a ; b;c")  # => ["a", ";", "b", ";", "c"]
```

## UTF-8 and UTF-16

A string is matched as it is held. A UTF-8 string (or US-ASCII, or binary holding UTF-8) is checked before it is read:
one that is not UTF-8 raises `ArgumentError`, and is never matched or read as U+FFFD. A UTF-16LE string is matched as
UTF-16, lone surrogates and all, with positions in code units.

```ruby
require "corvus_regex_ecma262"

dot_b = CorvusRegexEcma262.compile(".b", "u")
m = dot_b.match("a😀b")
m.offset                                           # => [1, 3]
m.byteoffset                                       # => [1, 6]
dot_b.match("a😀b".encode("UTF-16LE")).offset      # => [1, 4]

dot_b.match?("\xff".dup.force_encoding("UTF-8"))   # raises ArgumentError
```

## Patterns and texts from outside

A match has no limit by default. A program that matches a pattern or a text it did not write gives the pattern a match
timeout in seconds, as a .NET `Regex` has: a match that runs past it, or whose backtracking memory reaches its cap,
raises `MatchLimitError`. No pattern can overflow the stack. `CorvusRegexEcma262.default_timeout =` sets the timeout of
every pattern compiled after it, and `match?` and `match` take a `timeout:` of their own.

```ruby
require "corvus_regex_ecma262"

slow = CorvusRegexEcma262.compile('^(?:(a+)\1*)+$', "", timeout: 0.1)
slow.timeout                                       # => 0.1
slow.match?(("a" * 60) + "b")                      # raises CorvusRegexEcma262::MatchLimitError
```

## The edition and the version of Unicode

JSON Schema 2020-12 names the grammar of ECMAScript 2020. `edition: :es2020` refuses what later editions added: the
`d` and `v` flags, modifier groups, a group name used twice, and property names outside the 2020 tables. The version of
Unicode is chosen apart from it with `unicode_version:`: 13, 17, 18, `:latest` (18) or nil, the default (V8's, 17).
Both are read when the pattern is compiled, so a match costs the same whatever they are.

```ruby
require "corvus_regex_ecma262"

greek = CorvusRegexEcma262.compile('^\p{Script=Greek}+$', "u", timeout: 1.0, edition: :es2020, unicode_version: 13)
greek.match?("αβγ")                                # => true
greek.unicode_version                              # => 13

# Vithkuqi is in Unicode 14 and later, so not in Unicode 13.
CorvusRegexEcma262.valid?('\p{Script=Vithkuqi}', "u", unicode_version: 13)  # => false
```

## Differences from Regexp

- The grammar is ECMA-262's, not Onigmo's. The flags are a string as `RegExp` takes them, and `(?i:...)` groups set
  them inside a pattern; there is no `(?i)` prefix for the whole pattern, no possessive quantifiers, no atomic groups,
  no `\A`, `\z` or `\h`, no `(?<name>)` local variables, and no recursion.
- `^` and `$` are the start and end of the text unless the `m` flag is set; in Ruby they are always the start and end
  of a line. `.` excludes LF, CR, U+2028 and U+2029 unless the `s` flag is set.
- `\d` is `[0-9]`, `\w` the 63 ASCII word characters, `\s` ECMAScript's white space and line terminators, and `\b`
  reads `\w`.
- A replacement template writes a group as `$1` or `$<name>`, and `$&`, `` $` `` and `$'` are the match and the text
  before and after it; Ruby's `sub` writes them `\1` and `\k<name>`.
- `split` is JavaScript's, which puts what the groups captured between the pieces, as Ruby's does, but keeps empty
  pieces at the end and takes a limit on the number of pieces.
- `Regexp.timeout` bounds a match's time; a match timeout here bounds its time and its backtracking memory, and a
  pattern without a backreference is matched in time linear in the text.

## Where next

- [The API reference](https://rubydoc.info/gems/corvus_regex_ecma262) on RubyDoc.info.
- [The README](../README.md).
- [The benchmark page](https://corvus-oss.org/corvus-regex-ecma262-benchmarks/), with every engine measured nightly.
