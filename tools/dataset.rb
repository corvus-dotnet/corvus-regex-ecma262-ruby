# frozen_string_literal: true

# Runs this gem over the ECMA-262 regular expression test data (github.com/corvus-dotnet/ecma262-regex-test-data),
# judged by the data's own rule ("How a runner judges an engine" in its README) exactly as the C library's runner
# judges it:
#
#   ruby -Ilib tools/dataset.rb <data directory> <wrong-cases output file> [--files <glob>] [--workers N]
#
# Each record is asked about under each grammar V8 found it valid in: the record's flags with u added (the unicode
# answers), the record's flags alone (the legacy answers) and, in the file that has them, the flags with v added (the
# unicode_sets answers). A text is matched as a UTF-16LE string (positions in code units, as the data gives them) and
# as a UTF-8 string (positions in bytes); a text with a lone surrogate has no UTF-8 form and is matched as UTF-16LE
# alone. Records marked v8_deviation are left out. Any difference from V8 is a wrong answer; a refusal of a valid
# pattern, an acceptance of an invalid one, and a match that reaches its limit are counted apart and listed too.
# captures.jsonl is judged on exec, the global search, the sticky flag, replace and split. A match is given 2 seconds.
#
# Ruby's JSON refuses a lone surrogate, which the data holds, so each lone surrogate escape is read as a code point of
# Plane 15's private use area (U+F0000 + its offset from U+D800), which the data does not use (a line that does is
# refused), and turned back into its code unit wherever the text is used.
require "json"
require "corvus_regex_ecma262"

module Dataset
  LIMIT = 2.0
  REPLACEMENT = "<$&|$1|$2|$10|$<a>|$$|$`|$'>"
  LONE = /[\u{F0000}-\u{F07FF}]/
  SURROGATE_ESCAPE = /\\\\|\\u(d[89ab][0-9a-f]{2})\\u(d[c-f][0-9a-f]{2})|\\u(d[89a-f][0-9a-f]{2})/i
  R = CorvusRegexEcma262

  module_function

  # The line with each lone surrogate escape written as the escape of its Plane 15 code point.
  def readable(line)
    raise "the data uses U+F0000-U+F07FF, which the runner reads lone surrogates as" if line.match?(/\\udb8[01]|[\u{F0000}-\u{F07FF}]/i)

    line.gsub(SURROGATE_ESCAPE) do |m|
      next m unless Regexp.last_match(3)

      v = 0xF0000 + Regexp.last_match(3).hex - 0xD800 - 0x10000
      format("\\u%04x\\u%04x", 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF))
    end
  end

  # The UTF-16 code units of a text as read.
  def units(s)
    s.each_codepoint.flat_map do |c|
      if c >= 0xF0000 && c <= 0xF07FF
        [0xD800 + c - 0xF0000]
      elsif c > 0xFFFF
        v = c - 0x10000
        [0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF)]
      else
        [c]
      end
    end
  end

  def utf16(s) = units(s).pack("v*").force_encoding(Encoding::UTF_16LE)
  def lone?(s) = s.match?(LONE)
  # UTF-8, a lone surrogate as U+FFFD (as String::from_utf16_lossy writes it).
  def utf8_lossy(s) = s.gsub(LONE, "�")

  # The pattern as the Rust runner shows it: through UTF-8 (a lone surrogate as U+FFFD), escaped.
  def shown(pattern) = escape(utf8_lossy(pattern))

  def escape(s)
    units(s).map { |u| u >= 0x20 && u < 0x7F && u != 0x5C ? u.chr : format("\\u%04x", u) }.join
  end

  # For each UTF-16 code unit index of a text (and its end), the UTF-8 byte offset; the low half of a pair is its
  # character's third byte.
  def byte_offsets(s)
    at = []
    b = 0
    s.each_char do |c|
      if c.ord > 0xFFFF
        at << b << (b + 2)
      else
        at << b
      end
      b += c.bytesize
    end
    at << b
  end

  Counts = Struct.new(:right, :wrong, :refused, :accepted, :limited, :errors) do
    def self.zero = new(0, 0, 0, 0, 0, 0)

    def add(o)
      members.each { |k| self[k] += o[k] }
      self
    end
  end

  def compile(pattern, flags)
    [R::Regex.new(utf8_lossy(pattern), flags), nil, false]
  rescue R::InvalidPatternError => e
    [nil, "PARSE: #{e.message}", false]
  rescue R::PatternTooLargeError => e
    [nil, "TOO-LARGE: #{e.message}", false]
  rescue R::Error => e
    [nil, "ERROR: #{e.message}", true]
  end

  def modes_of(r)
    valid = r["valid"] || {}
    modes = [["u", "unicode", valid["unicode"] == true], ["", "legacy", valid["legacy"] == true]]
    modes << ["v", "unicode_sets", valid["unicode_sets"] == true] if valid.key?("unicode_sets")
    modes
  end

  def judge_tests(name, r, pattern, c, w)
    flags = r["flags"].to_s
    head_pattern = shown(pattern)
    modes_of(r).each do |suffix, answer, valid|
      mode_flags = flags + suffix
      head = "#{name}\t/#{head_pattern}/#{mode_flags}"
      re, message, is_error = compile(pattern, mode_flags)
      unless re
        c.errors += 1 if is_error
        if valid
          c.refused += 1
          w << "REFUSED\t#{head}\t#{message.lines.first&.chomp}"
        end
        next
      end
      unless valid
        c.accepted += 1
        w << "ACCEPTED-INVALID\t#{head}"
        next
      end
      (r["tests"] || []).each do |test|
        expected = test[answer]
        text = test["text"]
        next unless [true, false].include?(expected) && text

        %w[utf16 utf8].each do |enc|
          next if enc == "utf8" && lone?(text)

          subject = enc == "utf16" ? utf16(text) : text
          begin
            got = re.match?(subject, timeout: LIMIT)
          rescue R::MatchLimitError => e
            c.limited += 1
            w << "LIMIT\t#{head}\t#{escape(text)}\t#{enc}\t#{e.message.include?('memory') ? 'memory' : 'time'}"
            next
          end
          if got == expected
            c.right += 1
          else
            c.wrong += 1
            w << "WRONG\t#{head}\t#{escape(text)}\t#{enc}\texpected #{expected}"
          end
        end
      end
    end
  end

  # Whether a match's groups are the expected [start, end] pairs (nil for a group that did not take part), expected
  # positions mapped by map (identity when nil), the match's read in bytes when bytes is set (code units otherwise).
  def same_slots(expected, m, map, bytes)
    return expected.nil? && m.nil? if expected.nil? || m.nil?
    return false unless expected.length == m.size

    expected.each_with_index.all? do |e, g|
      got = bytes ? m.byteoffset(g) : m.offset(g)
      if e.nil?
        got == [nil, nil]
      else
        got == (map ? [map[e[0]], map[e[1]]] : e)
      end
    end
  end

  def judge_all(matches, all, map, bytes)
    n = 0
    matches.each do |m|
      break if n >= all.length
      return false if all[n].nil?

      s, t = all[n][0]
      return false unless (bytes ? m.byteoffset : m.offset) == (map ? [map[s], map[t]] : [s, t])

      n += 1
    end
    !((all.length < 20 && n != all.length) || (all.length == 20 && n < 20))
  end

  def same_split(expected, got, convert)
    expected.is_a?(Array) && expected.length == got.length &&
      expected.zip(got).all? { |e, g| e.nil? ? g.nil? : !g.nil? && convert.call(e) == g }
  end

  def judge_mode(where, a, text, re, g, y, c, w)
    check = lambda do |what, ok|
      if ok
        c.right += 1
      else
        c.wrong += 1
        w << "WRONG\tcaptures.jsonl\t#{where}\t#{what}"
      end
    end
    u16 = utf16(text)
    has_lone = lone?(text)
    byte_at = has_lone ? nil : byte_offsets(text)
    exec = a["exec"]
    begin
      m = re.match(u16, timeout: LIMIT)
    rescue R::MatchLimitError
      c.limited += 1
      w << "LIMIT\tcaptures.jsonl\t#{where}"
      return
    end
    check.call("exec", same_slots(exec, m, nil, false))
    check.call("exec-utf8", same_slots(exec, re.match(text), byte_at, true)) unless has_lone

    all = a["all"] || []
    ok = true
    n = 0
    g.each_match(u16) do |mm|
      break if n >= all.length

      unless same_slots(all[n], mm, nil, false)
        ok = false
        break
      end
      n += 1
    end
    ok = false if (all.length < 20 && n != all.length) || (all.length == 20 && n < 20)
    check.call("all", ok && judge_all(g.each_match(u16), all, nil, false))
    check.call("all-utf8", judge_all(g.each_match(text), all, byte_at, true)) unless has_lone

    unless text.empty?
      sticky = a["sticky"]
      check.call("sticky", same_slots(sticky, y.match(u16, 1), nil, false))
      if !has_lone && (byte_at[1] >= text.bytesize || (text.getbyte(byte_at[1]) & 0xC0) != 0x80)
        pos = text.byteslice(0, byte_at[1]).length
        check.call("sticky-utf8", same_slots(sticky, y.match(text, pos), byte_at, true))
      end
    end

    replace = a["replace"]
    replace_all = a["replaceAll"]
    check.call("replace", !replace.nil? && re.replace(u16, REPLACEMENT) == utf16(replace))
    check.call("replaceAll", !replace_all.nil? && g.replace(u16, REPLACEMENT) == utf16(replace_all))
    unless has_lone
      check.call("replace-utf8", !replace.nil? && re.replace(text, REPLACEMENT) == utf8_lossy(replace))
      check.call("replaceAll-utf8", !replace_all.nil? && g.replace(text, REPLACEMENT) == utf8_lossy(replace_all))
    end

    to16 = ->(e) { utf16(e) }
    check.call("split", same_split(a["split"], re.split(u16), to16))
    check.call("split3", same_split(a["split3"], re.split(u16, 3), to16))
  end

  def judge_captures(r, pattern, c, w)
    flags = r["flags"].to_s
    valid = r["valid"] || {}
    head_pattern = shown(pattern)
    cache = {}
    make = ->(f) { cache.fetch(f) { cache[f] = compile(pattern, f)[0] } }
    (r["tests"] || []).each do |test|
      next if test["v8_deviation"]

      text = test["text"]
      next if text.nil?

      %w[unicode legacy].each do |mode|
        next unless valid[mode] == true && test.key?(mode)

        mode_flags = flags + (mode == "unicode" ? "u" : "")
        where = "/#{head_pattern}/#{mode_flags}\t#{escape(text)}"
        re = make.call(mode_flags)
        g = make.call("#{mode_flags}g")
        y = make.call("#{mode_flags}y")
        if re.nil? || g.nil? || y.nil?
          c.refused += 1
          w << "REFUSED\tcaptures.jsonl\t#{where}"
          next
        end
        begin
          judge_mode(where, test[mode], text, re, g, y, c, w)
        rescue StandardError => e
          c.errors += 1
          w << "ERROR\tcaptures.jsonl\t#{where}\t#{e.class}: #{e.message}"
        end
      end
    end
  end

  def judge_lines(name, lines)
    c = Counts.zero
    w = []
    records = skipped = 0
    lines.each do |line|
      next if line.strip.empty?

      r = JSON.parse(readable(line))
      if r["v8_deviation"]
        skipped += 1
        next
      end
      records += 1
      pattern = r["pattern"]
      next if pattern.nil?

      name == "captures.jsonl" ? judge_captures(r, pattern, c, w) : judge_tests(name, r, pattern, c, w)
    end
    [c, w, records, skipped]
  end

  # Runs the lines in workers, each a forked process, and gathers their counts (in this process where there is no
  # fork, as on Windows).
  def judge_file(name, lines, workers)
    return [judge_lines(name, lines)] unless Process.respond_to?(:fork)

    slices = lines.each_slice([(lines.length.to_f / workers).ceil, 1].max).to_a
    readers = slices.map do |slice|
      reader, writer = IO.pipe
      pid = fork do
        reader.close
        writer.binmode.write(Marshal.dump(judge_lines(name, slice)))
        writer.close
        exit!(0)
      end
      writer.close
      [pid, reader]
    end
    readers.map do |pid, reader|
      result = Marshal.load(reader.binmode.read) # rubocop:disable Security/MarshalLoad -- our own child's output
      reader.close
      Process.wait(pid)
      result
    end
  end

  def main(argv)
    data, wrong_path, *rest = argv
    abort "usage: ruby -Ilib tools/dataset.rb <data directory> <wrong-cases file> [--files glob] [--workers N]" unless wrong_path
    files_glob = "*.jsonl"
    workers = 4
    rest.each_slice(2) do |flag, value|
      case flag
      when "--files" then files_glob = value
      when "--workers" then workers = Integer(value)
      else abort "unknown option #{flag}"
      end
    end
    files = Dir.children(data).select { |f| f.end_with?(".jsonl") && File.fnmatch(files_glob, f) }.sort
    total = Counts.zero
    wrong = []
    records = skipped = 0
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    files.each do |name|
      lines = File.readlines(File.join(data, name), chomp: true, encoding: "UTF-8")
      file_total = Counts.zero
      judge_file(name, lines, workers).each do |c, w, rec, skip|
        file_total.add(c)
        wrong.concat(w)
        records += rec
        skipped += skip
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
      puts format("%-24s right %10d  wrong %6d  refused-valid %4d  accepted-invalid %4d  limit %4d  %6.1fs",
                  name, file_total.right, file_total.wrong, file_total.refused, file_total.accepted, file_total.limited,
                  elapsed)
      $stdout.flush
      total.add(file_total)
    end
    File.write(wrong_path, wrong.sort.map { |l| "#{l}\n" }.join)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    puts format("\nrecords %d (skipped %d deviations)  right %d  wrong %d  refused-valid %d  accepted-invalid %d  " \
                "limit %d  errors %d  in %.1fs", records, skipped, total.right, total.wrong, total.refused, total.accepted,
                total.limited, total.errors, elapsed)
    total.wrong + total.refused + total.accepted + total.errors + total.limited
  end
end

exit(Dataset.main(ARGV).zero? ? 0 : 1) if $PROGRAM_NAME == __FILE__
