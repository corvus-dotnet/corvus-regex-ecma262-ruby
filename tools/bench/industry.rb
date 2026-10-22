# frozen_string_literal: true

# The Industry benchmark from Ruby: each workload counted by each engine, in nanoseconds per count, under the
# interleaved protocol every Corvus ECMA-262 engine's harness follows (docs/benchmarks/README.md in
# corvus-regex-ecma262-rs), a port of the C harness's driver (tools/c/industry.c there):
#
#   ruby tools/bench/industry.rb <workloads.json> [--engines corvus-utf8,corvus-utf16,ruby,v8] [--v8 <industry.mjs>]
#        [--rounds 3] [--seconds 0.7] [--passes 7] [--spread 0.05] [--filter <substring of the id>] [--out <json>]
#
# The workloads are the outer loop, each workload's rounds next and the engines innermost, their order turned by one
# each round, so that a workload's rounds are seconds apart, as its engines are. Each figure is a child process of its
# own (`industry.rb --one`, or `node industry.mjs --one` for V8), which warms for two fifths of its seconds, then times
# `passes` passes of as many counts as fit the rest and reports their median. A workload's figure for an engine is the
# median of its rounds, with the fastest and the slowest round as its spread; a figure whose spread, (slowest -
# fastest) / median, is over --spread is listed in the run's facts (spread_over) and on stderr. A child that does not
# finish in two minutes is stopped and recorded as such.
#
# The engines, each counting every match of a global search as a Ruby program that wants every match would:
# - corvus-utf8 and corvus-utf16: this gem with the workload's flags and u, over the text as a UTF-8 String and as a
#   UTF-16LE String, each match taken as a Match with each_match;
# - ruby: Ruby's Regexp (Onigmo), which does not claim ECMA-262, given the pattern as it is with the flags i, m and s
#   (Ruby's m is ECMA-262's s; ^ and $ are always at lines), each match taken with String#scan;
# - v8: Node's RegExp (--v8), with gu added.
#
# The texts are those of the reference run, in CORVUS_REGEX_TEXTS (or ~/.local/share/corvus-regex-benchmarks); the run
# unzips each once into a directory of its own (CORVUS_REGEX_PLAIN), which the children read. POSIX only: the benchmark
# runs on Linux, in the image.
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "timeout"
require "zlib"
require "etc"

module Industry
  DEFAULT_ENGINES = %w[corvus-utf8 corvus-utf16 ruby].freeze
  NOT_ECMA262 = %w[ruby].freeze
  LABELS = { "corvus-utf8" => "corvus-regex-ecma262 UTF-8", "corvus-utf16" => "corvus-regex-ecma262 UTF-16",
             "ruby" => "Regexp", "v8" => "V8" }.freeze

  module_function

  def text_dir = ENV["CORVUS_REGEX_TEXTS"] || File.join(Dir.home, ".local", "share", "corvus-regex-benchmarks")

  def load_text(file)
    plain = ENV.fetch("CORVUS_REGEX_PLAIN", nil)
    if plain
      path = File.join(plain, file.delete_suffix(".gz"))
      return File.read(path, encoding: "UTF-8") if File.exist?(path)
    end
    Zlib::GzipReader.open(File.join(text_dir, file)) { |gz| gz.read.force_encoding("UTF-8") }.delete_prefix("﻿")
  end

  def flags_u(flags) = flags.match?(/[uv]/) ? flags : "#{flags}u"

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # Warms, then times passes: the median, the fastest and the slowest pass in nanoseconds per count, the count, and
  # the counts timed.
  def measure(seconds, passes, count)
    expected = count.call
    warm_end = now + (seconds * 0.4)
    reps = 0
    while now < warm_end
      raise "the count changed" unless count.call == expected

      reps += 1
    end
    per_pass = [(reps * 0.6 / passes).round, 1].max
    times = Array.new(passes) do
      t0 = now
      per_pass.times { count.call }
      (now - t0) * 1e9 / per_pass
    end.sort
    [times[passes / 2], times[0], times[-1], expected, per_pass * passes]
  end

  def one(path, index, engine, seconds, passes)
    workloads = JSON.parse(File.read(path, encoding: "UTF-8"))
    return { "error" => "no workload #{index}" } if index >= workloads.length

    w = workloads[index]
    text = load_text(w["file"])
    count =
      case engine
      when "corvus-utf8", "corvus-utf16"
        require "corvus_regex_ecma262"
        re = CorvusRegexEcma262::Regex.new(w["pattern"], flags_u(w["flags"]))
        subject = engine == "corvus-utf8" ? text : text.encode(Encoding::UTF_16LE)
        lambda do
          n = 0
          re.each_match(subject) { n += 1 }
          n
        end
      when "ruby"
        options = 0
        options |= Regexp::IGNORECASE if w["flags"].include?("i")
        options |= Regexp::MULTILINE if w["flags"].include?("s")
        re = Regexp.new(w["pattern"], options)
        lambda do
          n = 0
          text.scan(re) { n += 1 }
          n
        end
      else
        return { "error" => "unknown engine #{engine}" }
      end
    median, low, high, expected, reps = measure(seconds, passes, count)
    { "median" => median.round(1), "min" => low.round(1), "max" => high.round(1), "count" => expected, "reps" => reps }
  rescue StandardError, SyntaxError => e
    { "error" => "#{e.class}: #{e.message}" }
  end

  # One figure in a child process: the child's line of JSON, or one with the error.
  def figure(v8, path, index, spec, seconds, passes)
    engine, program = spec.split("@", 2)
    cmd =
      if engine == "v8"
        ["node", v8, "--one", path, index.to_s, seconds, passes]
      elsif program
        [program, "--one", path, index.to_s, engine, seconds, passes]
      else
        [RbConfig.ruby, *$LOAD_PATH.grep(/corvus/).flat_map { |p| ["-I", p] }, __FILE__, "--one", path, index.to_s,
         engine, seconds, passes]
      end
    out = +""
    Open3.popen3(*cmd) do |stdin, stdout, _stderr, thread|
      stdin.close
      begin
        Timeout.timeout(120) { out = stdout.read }
      rescue Timeout::Error
        Process.kill("KILL", thread.pid)
        return { "error" => "did not finish in two minutes" }
      end
    end
    line = out.lines.last
    return { "error" => "the process ended without figures" } unless line

    JSON.parse(line)
  rescue JSON::ParserError
    { "error" => "the process wrote no figures" }
  end

  def field(path, prefix)
    File.foreach(path).find { |l| l.start_with?(prefix) }&.split(":", 2)&.last&.strip.to_s
  rescue SystemCallError
    ""
  end

  def first_line(cmd) = `#{cmd} 2>/dev/null`.lines.first.to_s.strip

  def main(argv)
    if argv.first == "--one"
      _, path, index, engine, seconds, passes = argv
      puts JSON.generate(one(path, Integer(index), engine, Float(seconds), Integer(passes)))
      return 0
    end
    path = argv.shift
    opts = { "rounds" => "3", "seconds" => "0.7", "passes" => "7", "spread" => "0.05" }
    argv.each_slice(2) { |k, v| opts[k.delete_prefix("--")] = v }
    engines = opts["engines"]&.split(",") || (DEFAULT_ENGINES + (opts["v8"] ? ["v8"] : []))
    rounds = Integer(opts["rounds"])
    limit = Float(opts["spread"])
    workloads = JSON.parse(File.read(path, encoding: "UTF-8"))
    chosen = workloads.each_index.select { |k| opts["filter"].nil? || workloads[k]["id"].include?(opts["filter"]) }

    # The texts unzipped once, for every child.
    plain = Dir.mktmpdir("corvus-regex-texts-rb-")
    workloads.each do |w|
      file = File.join(plain, w["file"].delete_suffix(".gz"))
      File.write(file, load_text(w["file"])) unless File.exist?(file)
    end
    ENV["CORVUS_REGEX_PLAIN"] = plain

    figures = engines.to_h { |e| [e, {}] }
    v8_engine = ""
    chosen.each_with_index do |k, c|
      rounds.times do |rnd|
        engines.length.times do |turn|
          e = engines[(turn + rnd) % engines.length]
          line = figure(opts["v8"], path, k, e, opts["seconds"], opts["passes"])
          fig = (figures[e][k] ||= { "each" => [], "line" => line })
          fig["line"] = line
          if line.key?("median")
            fig["each"] << line["median"]
          else
            warn format("%-13s %-62s %s", e, workloads[k]["id"], JSON.generate(line))
          end
          v8_engine = line["engine"] if e == "v8" && line["engine"]
        end
      end
      warn "workload #{c + 1} of #{chosen.length} done"
    end
    FileUtils.rm_rf(plain)

    over = []
    differ = []
    results = engines.to_h do |e|
      rows = chosen.to_h do |k|
        fig = figures[e][k] || { "each" => [], "line" => {} }
        line = fig["line"]
        each = fig["each"]
        wid = workloads[k]["id"]
        if each.length < rounds
          # A round with no figure (an error, a limit) makes the figure an error.
          next [wid, line.key?("error") ? line : { "error" => "a round gave no figure" }]
        end

        sorted = each.sort
        m = sorted.length.odd? ? sorted[sorted.length / 2] : (sorted[(sorted.length / 2) - 1] + sorted[sorted.length / 2]) / 2.0
        spread = m.positive? ? (sorted[-1] - sorted[0]) / m : 0
        if spread > limit
          over << format("%s %s %.1f%%", e, wid, spread * 100)
          warn format("SPREAD %-13s %-62s %.1f%% over %.1f%%", e, wid, spread * 100, limit * 100)
        end
        n = line["count"]
        entry = { "median" => m.round(1), "min" => sorted[0], "max" => sorted[-1], "count" => n, "rounds" => each.length,
                  "spread" => spread.round(4), "each" => each }
        # Without V8 in the run (V8=0), its count as the workloads carry it (v8Count, from the central run).
        oracle = figures.key?("v8") ? figures.dig("v8", k, "line", "count") : workloads[k]["v8Count"]
        if oracle && n != oracle && e != "v8"
          differ << "#{e} #{wid} #{n} vs V8 #{oracle}"
          warn format("COUNT  %-13s %-62s %s against V8's %s", e, wid, n, oracle)
          entry = NOT_ECMA262.include?(e) ? entry.merge("differs" => "#{LABELS[e]} #{n}, V8 #{oracle}") : { "error" => "counted #{n} where V8 counts #{oracle}" }
        end
        [wid, entry]
      end
      [e, rows]
    end

    $LOAD_PATH.unshift(*$LOAD_PATH.grep(/corvus/))
    require "corvus_regex_ecma262"
    facts = {
      "cpu" => field("/proc/cpuinfo", "model name"),
      "cores" => Etc.nprocessors.to_s,
      "affinity" => field("/proc/self/status", "Cpus_allowed_list"),
      "os" => "#{RbConfig::CONFIG['host_os']} #{first_line('uname -r')}",
      "load" => first_line("cut -d' ' -f1 /proc/loadavg"),
      "ruby" => RUBY_DESCRIPTION,
      "commit" => ENV["CORVUS_COMMIT"].to_s.empty? ? first_line("git rev-parse HEAD") : ENV.fetch("CORVUS_COMMIT"),
      "date" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
      "seconds" => opts["seconds"], "passes" => opts["passes"],
      "runner" => ENV.fetch("RUNNER_NAME", ""), "runner_os" => ENV.fetch("RUNNER_OS", ""),
      "image" => [ENV.fetch("ImageOS", ""), ENV.fetch("ImageVersion", "")].reject(&:empty?).join(" "),
      "corvus-regex-ecma262" => CorvusRegexEcma262::VERSION,
      "onigmo" => "Ruby #{RUBY_VERSION}",
      "rounds" => rounds.to_s, "protocol" => "interleaved", "spread_limit" => format("%g", limit),
      "spread_over" => over.join("; "), "counts_differ" => differ.join("; "), "v8" => v8_engine
    }
    data = { "facts" => facts, "end" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"), "results" => results }
    if opts["out"]
      File.write(opts["out"], JSON.generate(data))
    else
      puts JSON.generate(data)
    end
    0
  end
end

require "fileutils"
exit(Industry.main(ARGV)) if $PROGRAM_NAME == __FILE__
