# Contributing

This guide is for someone who wants to build the gem, run its tests and gates, and open a pull request. It covers the
tools, the build step by step, the gates every change must pass, and how a pull request is released. The
[design document](design.md) describes what is underneath.

## 1. Tools

| Tool | Needed for | Version |
|---|---|---|
| Ruby | Everything | 3.3 or later, with Bundler |
| Rust | The native extension | The toolchain CI names (1.98.0), installed with `rustup` |
| A C compiler and libclang | Building the extension (rb-sys reads Ruby's headers with bindgen) | Any recent GCC or Clang |
| Git | The repository and the test data | Any recent version |
| Node.js | The test data for other versions of Unicode and for ECMAScript 2020, and the V8 rows of the harness | 24 (the V8 it carries is the oracle) |
| PowerShell 7 | The release scripts (`tools/release`) | 7.4 or later |

- **Windows:** RubyInstaller with the MSYS2 devkit (`winget install RubyInstallerTeam.RubyWithDevKit.3.4`),
  `winget install Rustlang.Rustup Git.Git OpenJS.NodeJS.LTS Microsoft.PowerShell`.
- **Linux:** Ruby from the distribution or a version manager (rbenv, ruby-install), with its headers; `rustup` from
  [rustup.rs](https://rustup.rs); `clang` and `libclang-dev` from the distribution; Node.js 24 from nodejs.org.
- **macOS:** `brew install ruby rustup git node@24 powershell`, then `rustup-init`, with the Xcode command line tools.

## 2. Getting the sources

```
git clone https://github.com/corvus-dotnet/corvus-regex-ecma262-ruby.git
git clone https://github.com/corvus-dotnet/ecma262-regex-test-data.git   # beside it: the test data
cd corvus-regex-ecma262-ruby
bundle install
```

The test data is the oracle for the engine. It is not vendored; the commands below assume it at
`../ecma262-regex-test-data`.

## 3. Building and testing, step by step

Every command runs from the repository root.

1. **Formatted and linted.** `cargo +1.98.0 fmt --check` and `cargo +1.98.0 clippy --all-targets -- -D warnings` must
   pass.
2. **Build and test.** `bundle exec rake` compiles the extension into `lib/` and runs the tests, the getting-started
   page's examples among them (`test/test_getting_started.rb`).
3. **The test data.** `ruby -Ilib tools/dataset.rb ../ecma262-regex-test-data/data wrong-cases.tsv` must report 0
   wrong, 0 refused and 0 at a limit. For the other versions of Unicode and for ECMAScript 2020, write the data with
   its own scripts and run it with the gem set to match:

   ```
   node ../ecma262-regex-test-data/unicode.js apply 13.0 /tmp/u13 ../ecma262-regex-test-data/data
   ruby -Ilib tools/dataset.rb /tmp/u13 wrong-u13.tsv --unicode 13
   node ../ecma262-regex-test-data/edition.js apply /tmp/es2020 "" ../ecma262-regex-test-data/data
   ruby -Ilib tools/dataset.rb /tmp/es2020 wrong-es2020.tsv --edition es2020
   ```

## 4. The crate and the native gems

The engine is the `corvus-regex-ecma262` crate from crates.io, at the version the extension's `Cargo.toml` names; a fix
to the engine is made in [the crate's repository](https://github.com/corvus-dotnet/corvus-regex-ecma262-rs), released,
and taken here by moving that version. `version.rb`, the extension's `Cargo.toml` and `Cargo.lock` hold `0.0.0` and
name one version, which CI checks; a release writes its own. `rubygems-build.yml` builds every native gem (with
rb-sys-dock, for Ruby 3.3, 3.4 and 4.0) and the source gem, then installs each on its platform as a user installs it
and runs the tests and the test data through it.

## 5. Benchmarks

`tools/bench/run.sh <workloads.json> <texts directory> <out.json>` runs this gem, Ruby's `Regexp` and V8 over the
Industry workloads; the script lists what it needs and its settings. The published figures are on
[the benchmark page](https://corvus-oss.org/corvus-regex-ecma262-benchmarks/), which runs this repository's harness
image each night beside every other engine; a run on another machine is comparable with itself, never with the page.

## 6. What a pull request needs

- **The gates of section 3** passing on the change as pushed.
- **A fix to the engine's answers in the crate**, with its case in the test data first: the data repository's
  families are built around the faults found, with V8 as the oracle.
- **A failing test first** for a bug in the gem: the test that reproduces it, then the fix.
- **The design document kept current**, describing the gem as it is.
- **Comments** on every public method of `lib/`, since the API reference on RubyDoc.info is generated from them.
- **The getting-started page** kept true: its examples are run by the tests.

### Conventions

- The extension is Rust, formatted by `rustfmt` and clean under clippy at `-D warnings`; the library is Ruby with
  `frozen_string_literal`.
- A string is matched where it lies, in its own encoding, and a match comes back as one array of positions.

## 7. Releases

Every pull request merged into main releases what it changed, unless it is labelled `no_release`. `auto-release.yml`
runs `tools/release/release.ps1` on the merge: when the gem changed since its last tag (`Cargo.toml`, `Cargo.lock`, the
gemspec, `Rakefile`, `ext/`, `lib/`, or a published document), it makes a GitHub release tagged `v<version>` with the
next patch version, and `rubygems-publish.yml` builds, tests and pushes every gem to RubyGems by trusted publishing. A
change to the benchmark harness alone is a harness release, which publishes the harness image. A pull request that
needs a minor or major version sets `nextVersion` in `.github/release.json`; a minor version is a breaking change.

`main` is protected by a ruleset: changes arrive by pull request, and the `CI gate` and `Harness image` checks must be
green on the branch as it will merge.
