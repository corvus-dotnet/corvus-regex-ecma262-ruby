# frozen_string_literal: true

# The examples of the getting-started page the documentation site publishes (docs/getting-started.md), run as tests:
# each block of Ruby runs on its own, a line that ends "# => value" checks that its expression is the value, and a
# line that ends "# raises Error" checks that it raises that error.
require "minitest/autorun"
require "corvus_regex_ecma262"

class TestGettingStarted < Minitest::Test
  PAGE = File.expand_path("../docs/getting-started.md", __dir__)

  # Where the examples run: each check is a call on it.
  class Example
    def initialize(test) = @test = test

    def check(actual, expected, line)
      @test.assert_equal expected, actual, "docs/getting-started.md:#{line}"
    end

    def raises(error, line, &)
      @test.assert_raises(error, "docs/getting-started.md:#{line}", &)
    end
  end

  # Each block of Ruby with the line of the page it starts on.
  def self.blocks
    lines = File.readlines(PAGE, chomp: true)
    found = []
    lines.each_with_index do |line, i|
      next unless line == "```ruby"

      stop = (i + 1...lines.size).find { |j| lines[j] == "```" }
      found << [lines[(i + 1)...stop], i + 2]
    end
    found
  end

  def test_the_page_has_its_examples
    assert_operator self.class.blocks.size, :>=, 5
  end

  blocks.each_with_index do |(lines, first), n|
    define_method("test_example_#{n + 1}") do
      checks = 0
      source = lines.each_with_index.map do |line, k|
        at = first + k
        if (m = line.match(/\A(\s*)(.+?)\s+# => (.+)\z/))
          checks += 1
          "#{m[1]}check((#{m[2]}), (#{m[3]}), #{at})"
        elsif (m = line.match(/\A(\s*)(.+?)\s+# raises ([\w:]+)\z/))
          checks += 1
          "#{m[1]}raises(#{m[3]}, #{at}) { #{m[2]} }"
        else
          line
        end
      end
      assert_operator checks, :>, 0, "the example at docs/getting-started.md:#{first} checks nothing"
      Example.new(self).instance_eval(source.join("\n"), PAGE, first)
    end
  end
end
