# frozen_string_literal: true

require "rake/testtask"
require "rb_sys/extensiontask"

GEMSPEC = Gem::Specification.load("corvus_regex_ecma262.gemspec")

RbSys::ExtensionTask.new("corvus_regex_ecma262", GEMSPEC) do |ext|
  ext.lib_dir = "lib/corvus_regex_ecma262"
  ext.cross_compile = true
  # A native gem holds the compiled extensions, not the sources that build them.
  ext.cross_compiling do |spec|
    spec.files.reject! { |f| f.start_with?("ext/", "Cargo.") }
    spec.extensions.clear
    spec.dependencies.reject! { |d| d.name == "rb_sys" }
    # The glibc gems say so in their platform (x86_64-linux-gnu, not x86_64-linux). On a musl Ruby, RubyGems before
    # 4.0 ranks a gem for plain x86_64-linux equal to the musl gem, and "gem install" can take it: it does not load
    # there. A -gnu gem is never offered to a musl Ruby. RubyGems reads these platforms from 3.3.22.
    if spec.platform.os == "linux" && spec.platform.version.nil?
      spec.platform = Gem::Platform.new("#{spec.platform}-gnu")
      # A gem's metadata takes its platform from the first one the specification was given, which was the plain one.
      spec.original_platform = spec.platform.to_s
      spec.required_rubygems_version = ">= 3.3.22"
    end
  end
end

Rake::TestTask.new(:test) do |t|
  t.libs << "lib" << "test"
  t.test_files = FileList["test/test_*.rb"]
end

task default: %i[compile test]
