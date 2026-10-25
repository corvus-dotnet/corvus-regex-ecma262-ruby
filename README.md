# corvus-regex-ecma262 for Ruby

Regular expressions with the grammar and the answers of ECMA-262, the `RegExp` of JavaScript, for Ruby: the
[corvus-regex-ecma262](https://github.com/corvus-dotnet/corvus-regex-ecma262-rs) Rust crate, as a gem with native
builds for Linux (glibc and musl), macOS and Windows, x64 and arm64, for Ruby 3.3 and later.

- Every flag: `d`, `g`, `i`, `m`, `s`, `u`, `v` and `y`, with the grammar of each. Without `u` or `v` a pattern is
  read by the Annex B grammar and matched by UTF-16 code unit, as ECMA-262 matches it; with them, by code point. The
  `v` flag has nested classes, the difference and the intersection of classes, strings in a class and the properties
  of strings.
- ECMAScript 2025: lookbehind, named groups (and a name shared between alternatives), modifier groups such as
  `(?i:...)`, and every Unicode property ECMA-262 lists, from Unicode 17 tables the crate carries.
- UTF-8 strings (and US-ASCII, and binary strings holding UTF-8) and UTF-16LE strings, each matched as it is held.
  A pattern answers as it does in a browser or Node, which Ruby's `Regexp` does not: `^` and `$`, `.`, `\d`, `\w`,
  `\b`, case folding, `\p{...}` and the rest read as JavaScript reads them.
- A pattern without a backreference is matched in time proportional to its size times the text, and a pattern can be
  given a match timeout, as a `Regex` of .NET can, which every method honours and which caps the backtracking memory
  too, so with a timeout neither a pattern nor a text from outside can make a program hang.

**Compliance.** Over the [ECMA-262 test data](https://github.com/corvus-dotnet/ecma262-regex-test-data) (what V8 says
about its patterns and texts, test262's patterns and `exec` calls, the global search, `replace` and `split` among them,
and texts of bytes that are not UTF-8, which it refuses), through this gem over UTF-16LE and UTF-8 strings, it gives
every answer right and none wrong, refuses no valid pattern, accepts no invalid one and reaches no limit. CI runs
the whole data through each native gem on its platform.

## Install

```
gem install corvus_regex_ecma262
```

## Getting started

```ruby
require "corvus_regex_ecma262"

# The flags are those of new RegExp(pattern, flags).
date = CorvusRegexEcma262::Regex.new('(?<year>\d{4})-(?<month>\d{2})', "gu")

date.match?("due 2026-10")                          # => true
m = date.match("due 2026-10")
m[:year]                                            # => "2026"
m.offset                                            # => [4, 11]

# Every match of a global search, as matchAll makes it.
date.each_match("2026-10, 2027-01").map(&:to_s)     # => ["2026-10", "2027-01"]

# replace replaces every match with the g flag, and the first without it; a block may give each replacement.
date.replace("2026-10, 2027-01", "$<month>/$1")     # => "10/2026, 01/2027"
date.replace("2026-10") { |m| m[:month] }           # => "10"

# split splices in what the groups captured; a group that did not take part is nil.
CorvusRegexEcma262.compile('\s*(;)\s*').split("a ; b;c")  # => ["a", ";", "b", ";", "c"]
```

## The API

| | |
|---|---|
| `Regex.new(pattern, flags = "", timeout: nil)`, `CorvusRegexEcma262.compile` | Compiles a pattern as `new RegExp(pattern, flags)` does. `timeout:` is the match timeout in seconds (0 for none; nil for the default). |
| `CorvusRegexEcma262.default_timeout`, `.default_timeout=` | The timeout of every pattern compiled without one: nil (no limit) unless set. |
| `Regex.valid?(pattern, flags = "")` | Whether a pattern is valid, without compiling it. |
| `match?(string, pos = 0, timeout: nil)` | `RegExp.prototype.test` with `lastIndex` at `pos` (at `pos` alone with `y`). |
| `match(string, pos = 0, timeout: nil)` | The first match at or after `pos`, as `exec` finds it: a `Match`, or `nil`; with a block, the block's result. |
| `each_match(string)` | A global search as `matchAll` makes it: yields each `Match`, or returns an `Enumerator`. |
| `match_count(string)` | The number of matches of a global search, without making them. |
| `replace(string, replacement)`, `replace(string) { \|m\| ... }` | `String.prototype.replace`: the first match, or every match with `g`. |
| `replace_all(string, replacement)` | `String.prototype.replaceAll`: every match. |
| `split(string, limit = nil)` | `String.prototype.split`: an Array of Strings, `nil` for a group that did not take part. |
| `source`, `flags`, `timeout`, `group_count`, `names` | What the pattern is. |

A `Match` is read as a `MatchData` is: `m[g]` (a number, a name or a Symbol), `captures`, `named_captures`, `to_a`,
`values_at`, `pre_match`, `post_match`, `begin(g)`, `end(g)` and `offset(g)` (nil for a group that did not take part),
`byte_begin`, `byte_end` and `byteoffset`, `string` and `regexp`.

**Positions.** Over a UTF-8 string, `begin`, `end` and `offset` are in characters, as Ruby counts them, and the
`byte_` forms in bytes; over a UTF-16LE string they are in UTF-16 code units, as JavaScript counts them. Without `u` or
`v` a pattern is matched by UTF-16 code unit, so a match can take half of a character beyond the Basic Multilingual
Plane: over UTF-8 its text holds that half as U+FFFD and its character positions are the whole character's (its byte
positions are the character's start and third byte); over UTF-16LE it is the lone half, as in JavaScript.

**Errors.** `InvalidPatternError`, `InvalidFlagsError`, `PatternTooLargeError` and `MatchLimitError` (a match that
reached its timeout or its cap on backtracking memory) are each a `CorvusRegexEcma262::Error`, a `StandardError`. A
string that is not valid in its encoding raises `ArgumentError`; one in another encoding, `EncodingError`.

**Timeouts.** A pattern has a match timeout, as a `Regex` of .NET has: `Regex.new(pattern, flags, timeout: 1.0)`, or
for every pattern compiled after it `CorvusRegexEcma262.default_timeout = 1.0`. Every method that matches gives each
of its matches the timeout and raises `MatchLimitError` at it (a global search ends there); `match?` and `match` take a
`timeout:` of their own in its place. Without a timeout (the default) a match has no limit of time or of memory, so a
program that matches a pattern or a text it did not write should set one.

**Threads.** A `Regex` is frozen and may be used from any number of threads. A string cannot change while a global
search walks it.

## Benchmarks

The Industry workloads of dotnet/performance, this gem against Ruby's `Regexp` and V8, are on the central page,
[corvus-oss.org/corvus-regex-ecma262-benchmarks](https://corvus-oss.org/corvus-regex-ecma262-benchmarks/), measured
nightly on one runner with the engines of every other source.

## Repository

- `ext/corvus_regex_ecma262`: the native extension (magnus, over the crate); `lib/`: the Ruby API.
- `test/`: the tests; `tools/dataset.rb`: the test-data runner (`ruby -Ilib tools/dataset.rb <data> wrong.tsv`).
- `tools/bench`: the benchmark harness and the script the image runs; `Dockerfile`: the image the central page runs.

## Releasing

Every merged pull request releases what it changed, unless it is labelled `no_release`. `auto-release.yml` runs
`tools/release/release.ps1` on the merge commit: when the gem changed since its last tag (`Cargo.toml`, `Cargo.lock`,
the gemspec, `Rakefile`, `ext/` or `lib/`), it makes a GitHub release tagged `v<version>` with the next patch version,
and `rubygems-publish.yml` publishes it: `rubygems-build.yml` writes the version into `version.rb`, the extension's
`Cargo.toml` and `Cargo.lock` (which hold `0.0.0`; `tools/release/stamp.ps1`), builds the native gems and the source
gem and tests them, and they are pushed to RubyGems by trusted publishing. `harness-image.yml` publishes the harness
image under the same tag. When only the harness changed (`Dockerfile`, `tools/bench/`, `tools/benchmarks/`), the
release is `harness-<version>.<n>`, which publishes the image alone. A pull request that needs a minor or major version
sets `nextVersion` in `.github/release.json` (a minor version is a breaking change). A pull request labelled
`no_release` releases nothing, and its changes ship with the next release.

## Licence

Apache-2.0. See [LICENSE](LICENSE).
