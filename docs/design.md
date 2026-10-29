# corvus_regex_ecma262 for Ruby: design

An outline of the gem as it is: what it offers, how it is built and why, and how it is tested and measured. The
[getting-started page](getting-started.md) shows how to use it.

## 1. What it is

A Ruby gem of regular expressions with ECMA-262's grammar and answers (ECMAScript 2025), over UTF-8 and UTF-16LE
strings. It is a binding, through magnus, to the corvus-regex-ecma262 Rust crate, whose engine it uses as it is; its
`Match` reads as a `MatchData` does.

**Why ECMA-262.** JSON Schema, OpenAPI and many wire formats specify their patterns as ECMAScript regular
expressions. Ruby's `Regexp` is Onigmo's, with its own grammar and its own meaning for `^`, `$`, `\d`, `\w`, `\s`, `.`
and case folding, so a translation to it can never be exact. An engine that reads ECMA-262 directly, held to V8's
answers over a large data set (section 6), needs no translation.

## 2. Public surface

**Names.** `CorvusRegexEcma262::Regex` (or `CorvusRegexEcma262.compile`) has `match?` and `match` as `Regexp` does,
`each_match` (an `Enumerator` without a block), `match_count`, and `replace`, `replace_all` and `split`, the `RegExp`
names where ECMA-262's algorithm differs from Ruby's. A `Match` has `[]` by number, name or Symbol, `begin`, `end`,
`offset`, `captures`, `named_captures`, `pre_match` and `post_match`, and `byte_begin`, `byte_end` and `byteoffset`.

**Flags.** ECMA-262's, as a string, and nothing else.

**Edition and Unicode version.** By default a pattern is read with today's grammar (`edition: :current`) and V8's
version of Unicode (`unicode_version: nil`, 17 today). Either is overridden when the pattern is compiled,
independently: `:es2020` is the grammar JSON Schema 2020-12 names, and the versions are 13, 17, 18 and `:latest`. Both
are resolved when the pattern is compiled.

**Errors.** `InvalidPatternError`, `InvalidFlagsError`, `PatternTooLargeError` and `MatchLimitError` are each a
`CorvusRegexEcma262::Error`, a `StandardError`. A string that is not valid in its encoding raises `ArgumentError`; one
in another encoding, `EncodingError`.

**ECMA-262 algorithms.** `replace` substitutes as `GetSubstitution` does, replacing every match only with `g`, or takes
a block; `replace_all` always replaces every match. `split` follows `RegExp.prototype[Symbol.split]`.

**Input.** A string is matched as it is held: UTF-8 (or US-ASCII, or binary holding UTF-8) as UTF-8, with positions in
characters as Ruby counts them and byte positions beside them; UTF-16LE as UTF-16, with positions in code units.
Nothing is transcoded.

**Limits.** The crate's: a match timeout in seconds per pattern (`timeout:`) or for every pattern
(`CorvusRegexEcma262.default_timeout=`), with a `timeout:` of its own on `match?` and `match`; the size limits; and no
stack overflow.

## 3. Engine

The engine is the Rust crate's, which
[its design](https://github.com/corvus-dotnet/corvus-regex-ecma262-rs/blob/main/docs/design.md) describes. The gem's
work is between Ruby and the crate:

- **The extension** (`ext/corvus_regex_ecma262`) matches a string's bytes where they lie, as UTF-8 or as UTF-16LE code
  units, and gives a match's groups back as one flat array of positions in the engine's units, so a match costs Ruby
  one array.
- **The Ruby library** (`lib/`) is the API: it makes a `Match` from those positions, and turns byte positions into
  character positions, going on from the last one asked for, since a search asks in order; an ASCII string needs no
  turning.
- **Strings that change.** A search that runs a block walks the string frozen, copying a string that is not frozen as
  Ruby copies a string (sharing its bytes until either changes), so it cannot change under the search.
- **Threads.** A `Regex` is frozen and holds the crate's compiled pattern, shared between threads.

## 4. The native gems

Each release has a native gem for each platform (Linux with glibc and with musl, x86_64 and aarch64; macOS, x86_64 and
arm64; Windows x64), each holding the extension built for Ruby 3.3, 3.4 and 4.0, and a source gem that builds with
Rust. The glibc gems are named `-linux-gnu`, so RubyGems never offers one to a musl Ruby.

## 5. Targets and layout

Ruby 3.3 and later.

- `ext/corvus_regex_ecma262`: the native extension (magnus, over the crate); `lib/`: the Ruby API.
- `test/`: the tests, the getting-started page's examples among them; `tools/dataset.rb`: the test-data runner.
- `tools/bench` and `tools/benchmarks`: the benchmark harness; `tools/release`: the release scripts.

## 6. Testing

**The ECMA-262 test data.** [`ecma262-regex-test-data`](https://github.com/corvus-dotnet/ecma262-regex-test-data)
holds V8's answers: validity under each grammar, `test` answers, the positions of `exec`, the global search, `y`,
`replace` and `split`, and every `exec` call of test262. `tools/dataset.rb` runs all of it through each installed native
gem on its platform, over UTF-8 and UTF-16LE strings, with none wrong, refused or at a limit, and as the data's own
scripts write it for Unicode 13 and 18 and for ECMAScript 2020.

**Other tests.** Minitest over every method and both encodings, and the getting-started page's examples, through each
native gem installed as a user installs it, with the oldest and the newest Ruby it holds.

## 7. Benchmarks

The harness image, `ghcr.io/corvus-dotnet/corvus-regex-ecma262-ruby`, runs the Industry workloads of
`dotnet/performance` over this gem (UTF-8 and UTF-16), Ruby's `Regexp` and V8. The published figures are on
[the benchmark page](https://corvus-oss.org/corvus-regex-ecma262-benchmarks/), which runs every engine's image each
night; this repository publishes none of its own.

Three rows are not like for like with an engine that is not ECMA-262's, as the price of its rules under u: `.*` (`.`
excludes CR, so the CRLF text has more matches), `Sher[a-z]+|Hol[a-z]+` under i (the search must also find the long s
and the Kelvin sign), and `[a-q][^u-z]{13}x` (a supplementary character is two units, so the distance to the `x` is
not fixed).

## 8. Differences a Ruby user will meet

- `^` and `$` are the start and end of the text unless the `m` flag is set; in Ruby they are always a line's.
- The grammar is ECMA-262's, not Onigmo's: `(?i:...)` groups but no `(?i)` prefix, no possessive quantifiers, atomic
  groups, `\A`, `\z`, `\h` or recursion.
- A template writes a group as `$1` or `$<name>`, not `\1` or `\k<name>`.

The [getting-started page](getting-started.md) has the full list.
