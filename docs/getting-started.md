# Getting started with Ruby

## Introduction

`corvus_regex_ecma262` is a gem whose patterns answer as ECMAScript does. Where Ruby's `Regexp` has Onigmo's grammar
and its meaning for `^`, `$`, `\d`, `\w`, `\s`, `.`, case folding and Unicode properties, this gem has ECMA-262's, so a
pattern written for JavaScript, or taken from a JSON Schema, matches the same texts here as it does there. It is the
corvus-regex-ecma262 Rust crate, held to V8's answers on the ECMA-262 test data.

This guide covers:

- **Setup**: installing the gem.
- **Patterns and flags**: the flags are ECMA-262's letters, and what each one does.
- **The edition and the version of Unicode**: the grammar of ECMAScript 2020, and the Unicode tables a pattern reads.
- **Matching**: `match?`, `match`, `each_match`, `match_count`, `replace` and `split`, read as `MatchData` is.
- **Timeouts**: the limit of time and of memory a match may take.
- **UTF-8 and UTF-16**: strings matched as they are held, with positions in characters and in bytes.
- **Differences from Regexp**: what to expect when the two meet.

## Setup

```
gem install corvus_regex_ecma262
```

The gem has native builds for Linux (glibc and musl), macOS and Windows, x64 and arm64, and needs Ruby 3.3 or later.
With Bundler, add `gem "corvus_regex_ecma262"` to the Gemfile.

```ruby
require "corvus_regex_ecma262"
```

## Patterns and flags

A pattern is written as it would be in JavaScript, and the flags are the letters `RegExp` takes, as a string:

| Flag | Meaning |
|---|---|
| `d` | Accepted for completeness; indices are always kept. |
| `g` | `replace` replaces every match; without it, the first, as `String.prototype.replace` does. |
| `i` | Canonicalize of the mode in force: simple case folding with `u` or `v`, `toUpperCase` without. Never the locale. |
| `m` | `^` and `$` at line terminators. |
| `s` | The dot matches line terminators. |
| `u` | The `u` flag grammar; matched by code point. |
| `v` | Set notation and properties of strings; matched by code point. `u` and `v` together is an error, as in ECMA-262. |
| `y` | A match only at the start position. |

```ruby
require "corvus_regex_ecma262"

a = CorvusRegexEcma262::Regex.new('\p{Script=Greek}+', "u")
b = CorvusRegexEcma262::Regex.new('[[a-z]--[aeiou]]+', "v")
c = CorvusRegexEcma262::Regex.new('^(?<year>\d{4})-(?<month>\d{2})$', "u")

a.match?("αβγ")                                    # => true
b.match?("rhythm")                                 # => true
c.names                                            # => ["year", "month"]
```

With no flag the pattern is read with the Annex B grammar and matched by UTF-16 code unit, which is what ECMA-262 does
with no flag. JSON Schema's reading, the `u` flag first and Annex B when that refuses, is two compiles, each with the
match timeout, so no default timeout is needed:

```ruby
require "corvus_regex_ecma262"

def schema_pattern(pattern)
  CorvusRegexEcma262.compile(pattern, "u", timeout: 1.0)
rescue CorvusRegexEcma262::InvalidPatternError
  CorvusRegexEcma262.compile(pattern, "", timeout: 1.0)
end

schema_pattern('^\p{L}+$').flags                   # => "u"
schema_pattern('\-').flags                         # => ""
```

The second is an identity escape, which only Annex B allows. A pattern that is not valid raises `InvalidPatternError`,
whose message says why; invalid flags raise `InvalidFlagsError`. Every pattern has deterministic limits of size, and
`PatternTooLargeError` says when one is passed. Each is a `CorvusRegexEcma262::Error`.

```ruby
require "corvus_regex_ecma262"

CorvusRegexEcma262.compile("a{2,1}", "u")          # raises CorvusRegexEcma262::InvalidPatternError
CorvusRegexEcma262.compile("a", "uv")              # raises CorvusRegexEcma262::InvalidFlagsError
CorvusRegexEcma262.valid?("(?<n>a)(?<n>b)", "u")   # => false
```

## The edition and the version of Unicode

By default a pattern is read with today's grammar, ECMAScript 2025 (`edition: :current`), and with the tables of the
version of Unicode that V8 carries, 17 today (`unicode_version: nil`). Either can be overridden when the pattern is
compiled, each independently of the other.

JSON Schema 2020-12 names the grammar of ECMAScript 2020, which `edition: :es2020` selects in place of the default. It
refuses what later editions added, and nothing else: the `d` and `v` flags, modifier groups such as `(?i:...)`, a group
name used by two groups, and a property name or value that is not in the 2020 tables (such as `\p{Script=Yezidi}`). A
pattern it accepts has the same answers as in today's grammar.

The version of Unicode is chosen apart from the edition: `unicode_version:` 13, 17, 18, `:latest` (18 today) or nil,
the version of the V8 the answers are held to (17 today). It decides the members of each `\p{...}`, the characters of
a group name and the case folding of the `i` flag. `Regex#unicode_version` reports the version a pattern was compiled
with. Both settings are read when the pattern is compiled, so a match costs the same whichever is chosen.

```ruby
require "corvus_regex_ecma262"

# ECMAScript 2020 as its edition was published, with the Unicode of its year.
greek = CorvusRegexEcma262.compile('^\p{Script=Greek}+$', "u", timeout: 1.0, edition: :es2020, unicode_version: 13)
greek.match?("αβγ")                                # => true
greek.unicode_version                              # => 13

# Vithkuqi is in Unicode 14 and later, so not in Unicode 13.
CorvusRegexEcma262.valid?('\p{Script=Vithkuqi}', "u", unicode_version: 13)  # => false
```

## Matching

The methods are those of a `RegExp`, with the position as an argument where JavaScript keeps `lastIndex`. A match is a
`CorvusRegexEcma262::Match`, read as a `MatchData` is: by number, by name or by Symbol.

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

`match(string, pos)` is `exec` with `lastIndex` set to `pos`, and `y` anchors it there. `match?` and `match_count`
make no `Match`, and `each_match` without a block is an `Enumerator`, which makes each match as it is read. A `Regex` is
frozen, and is used from any number of threads; a string cannot change while a global search walks it.

## Timeouts

A match has no limit by default. A `Regex` made with `timeout:` (in seconds) abandons a match that reaches it, or that
reaches the cap on backtracking memory the timeout brings, with `MatchLimitError`, whatever the pattern:

```ruby
require "corvus_regex_ecma262"

slow = CorvusRegexEcma262.compile('^(?:(a+)\1*)+$', "", timeout: 0.1)
slow.timeout                                       # => 0.1
slow.match?(("a" * 60) + "b")                      # raises CorvusRegexEcma262::MatchLimitError
```

A `Regex` made without a timeout takes `CorvusRegexEcma262.default_timeout`, which is nil (no limit) unless set. A
program that matches patterns or texts from outside should set one, for example with
`CorvusRegexEcma262.default_timeout = 1.0` when it starts. `match?` and `match` take a `timeout:` of their own for one
match.

A pattern without a backreference is matched in time linear in the text, and no pattern can overflow the stack, so the
timeout is what bounds the others.

## UTF-8 and UTF-16

A string is matched as it is held, with no transcoding. A UTF-8 string (or US-ASCII, or binary holding UTF-8) is
matched as UTF-8, with `begin`, `end` and `offset` in characters, as Ruby counts them, and `byte_begin`, `byte_end` and
`byteoffset` in bytes. It is checked before it is read: a string that is not UTF-8 raises `ArgumentError`, and is never
matched or read as U+FFFD. A UTF-16LE string is matched as UTF-16, lone surrogates and all, with positions in code
units, as JavaScript counts them.

```ruby
require "corvus_regex_ecma262"

dot_b = CorvusRegexEcma262.compile(".b", "u")
m = dot_b.match("a😀b")
m.offset                                           # => [1, 3]
m.byteoffset                                       # => [1, 6]
dot_b.match("a😀b".encode("UTF-16LE")).offset      # => [1, 4]

dot_b.match?("\xff".dup.force_encoding("UTF-8"))   # raises ArgumentError
```

Under the `u` and `v` flags a character is a code point in both encodings, so a class, a dot or a quantifier takes a
four-byte sequence as one character. With no flag ECMA-262 matches by UTF-16 code unit, so a match can take half of a
character beyond the Basic Multilingual Plane: over UTF-8 its text holds that half as U+FFFD, and its character
positions are the whole character's.

## Differences from Regexp

The methods follow `RegExp`; the meaning follows ECMA-262. The differences a user coming from `Regexp` will meet:

- **The grammar.** No `(?i)` inline option (ECMA-262 has `(?i:...)` groups), no atomic groups, no possessive
  quantifiers, no `\A`, `\z` or `\h`, no named groups as local variables, no conditionals and no recursion.
- **Anchors and the dot.** `^` and `$` are the start and end of the text unless the `m` flag is set; in Ruby they are
  always the start and end of a line. `.` excludes LF, CR, U+2028 and U+2029 unless the `s` flag is set.
- **The character classes.** `\d` is `[0-9]`, `\w` is the 63 ASCII word characters, `\s` is ECMAScript's white space
  and line terminators, and `\b` reads `\w`.
- **Replacement.** A template writes a group as `$1` or `$<name>`, and `$&`, `` $` `` and `$'` are the match and the
  text before and after it; Ruby's `sub` writes them `\1` and `\k<name>`. `replace` replaces every match only with the
  `g` flag, and `replace_all` always does.
- **Split.** `split` is JavaScript's, which puts what the groups captured between the pieces, as Ruby's does, but keeps
  empty pieces at the end and takes a limit on the number of pieces.
- **Timeouts.** `Regexp.timeout` bounds a match's time; a timeout here bounds its time and its backtracking memory, and
  a pattern without a backreference is matched in time linear in the text.
