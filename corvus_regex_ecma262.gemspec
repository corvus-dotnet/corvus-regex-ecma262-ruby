# frozen_string_literal: true

require_relative "lib/corvus_regex_ecma262/version"

Gem::Specification.new do |spec|
  spec.name = "corvus_regex_ecma262"
  spec.version = CorvusRegexEcma262::VERSION
  spec.authors = ["endjin"]
  spec.summary = "ECMA-262 (JavaScript) regular expressions for Ruby: the grammar and the answers of RegExp, backed by Rust."
  spec.description = "Regular expressions that answer as JavaScript's RegExp does, every flag (dgimsuvy), over UTF-8 and " \
                     "UTF-16LE strings, with the corvus-regex-ecma262 Rust crate."
  spec.homepage = "https://github.com/corvus-dotnet/corvus-regex-ecma262-ruby"
  spec.license = "Apache-2.0"
  spec.required_ruby_version = ">= 3.3"
  spec.metadata = {
    "source_code_uri" => "https://github.com/corvus-dotnet/corvus-regex-ecma262-ruby",
    "bug_tracker_uri" => "https://github.com/corvus-dotnet/corvus-regex-ecma262-ruby/issues",
    "rubygems_mfa_required" => "true"
  }
  spec.files = Dir["lib/**/*.rb", "Cargo.{toml,lock}", "ext/**/*.{rs,toml,rb}", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]
  spec.extensions = ["ext/corvus_regex_ecma262/extconf.rb"]
  spec.add_dependency "rb_sys", "~> 0.9.130"
end
