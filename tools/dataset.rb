# frozen_string_literal: true

# Runs this gem over the ECMA-262 regular expression test data (github.com/corvus-dotnet/ecma262-regex-test-data),
# judged by the data's own rule ("How a runner judges an engine" in its README) exactly as the C library's runner
# judges it:
#
#   ruby -Ilib tools/dataset.rb <data directory> <wrong-cases output file> [--files <glob>] [--workers N]
#                               [--compliance <file>]
#
# Each record is asked about under each grammar V8 found it valid in: the record's flags with u added (the unicode
# answers), the record's flags alone (the legacy answers) and, in the file that has them, the flags with v added (the
# unicode_sets answers). A text is matched as a UTF-16LE string (positions in code units, as the data gives them) and
# as a UTF-8 string (positions in bytes); a text with a lone surrogate has no UTF-8 form and is matched as UTF-16LE
# alone. Records marked v8_deviation are left out. Any difference from V8 is a wrong answer; a refusal of a valid
# pattern, an acceptance of an invalid one, and a match that reaches its limit are counted apart and listed too.
# captures.jsonl is judged on exec, the global search, the sticky flag, replace and split. A match is given 2 seconds.
# ill-formed-utf8.jsonl holds bytes that are not UTF-8, each one answer over UTF-8 under each grammar the pattern is
# valid in, whose right answer is a refusal: the gem's ArgumentError for a UTF-8 string that is not.
#
# exec/test262.jsonl, the exec calls of test262 (in a directory of its own), is judged last: each call one exec with the
# record's flags from its lastIndex, right when the positions of the match and of every group, the named groups and, with
# g or y, the lastIndex after are V8's; one answer over the UTF-16LE string and, when the text holds no lone surrogate and
# lastIndex is not between the halves of a pair, one over the UTF-8 string with positions in bytes.
#
# With --compliance <file>, the engine's compliance object is written to the file, as the benchmark page reads it
# (docs/implementing-a-source.md in corvus-regex-ecma262-benchmarks): the counts, this runner and the calls it makes in
# each encoding, and what it leaves out, which for this gem is nothing.
#
# Ruby's JSON refuses a lone surrogate, which the data holds, so each lone surrogate escape is read as a code point of a
# block of 2,048 private use code points (the block's first + its offset from U+D800) and turned back into its code unit
# wherever the text is used. The block is chosen for each line from the blocks of Planes 15 and 16: the first whose
# code points the line does not hold, which is known when the line, read with that block, holds as many of them as it
# had lone surrogate escapes. So no character of the data is taken for a lone surrogate (test262's texts hold the ends
# of the private use ranges).
require "json"
require "corvus_regex_ecma262"

module Dataset
  LIMIT = 2.0
  REPLACEMENT = "<$&|$1|$2|$10|$<a>|$$|$`|$'>"
  # The first code point of each block a line's lone surrogates may be read as.
  BLOCKS = (0xF0000..0xFF000).step(0x800).to_a + (0x100000..0x10F000).step(0x800).to_a
  SURROGATE_ESCAPE = /\\\\|\\u(d[89ab][0-9a-f]{2})\\u(d[c-f][0-9a-f]{2})|\\u(d[89a-f][0-9a-f]{2})/i
  R = CorvusRegexEcma262

  module_function

  # The record of a line, its lone surrogates read as code points of the first block the line does not use.
  def read(line)
    BLOCKS.each do |block|
      written = 0
      rewritten = line.gsub(SURROGATE_ESCAPE) do |m|
        next m unless Regexp.last_match(3)

        written += 1
        v = block + Regexp.last_match(3).hex - 0xD800 - 0x10000
        format("\\u%04x\\u%04x", 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF))
      end
      r = JSON.parse(rewritten)
      next unless count_in(r, block) == written

      @block = block
      @lone = Regexp.new(format("[\\u{%x}-\\u{%x}]", block, block + 0x7FF))
      return r
    end
    raise "every block of Planes 15 and 16 is used by the line"
  end

  # How many code points of a block the strings of a value hold.
  def count_in(value, block)
    case value
    when String then value.each_codepoint.count { |c| c >= block && c < block + 0x800 }
    when Array then value.sum { |v| count_in(v, block) }
    when Hash then value.sum { |k, v| count_in(k, block) + count_in(v, block) }
    else 0
    end
  end

  # The UTF-16 code units of a text as read.
  def units(s)
    s.each_codepoint.flat_map do |c|
      if c >= @block && c < @block + 0x800
        [0xD800 + c - @block]
      elsif c > 0xFFFF
        v = c - 0x10000
        [0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF)]
      else
        [c]
      end
    end
  end

  def utf16(s) = units(s).pack("v*").force_encoding(Encoding::UTF_16LE)
  def lone?(s) = s.match?(@lone)
  # UTF-8, a lone surrogate as U+FFFD (as String::from_utf16_lossy writes it).
  def utf8_lossy(s) = s.gsub(@lone, "�")

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

  def judge_ill_formed(r, pattern, c, w)
    name = "ill-formed-utf8.jsonl"
    flags = r["flags"].to_s
    head_pattern = shown(pattern)
    modes_of(r).each do |suffix, _, valid|
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
        hex = test["bytes"]
        subject = [hex].pack("H*").force_encoding(Encoding::UTF_8)
        begin
          got = re.match?(subject, timeout: LIMIT)
        rescue R::MatchLimitError => e
          c.limited += 1
          w << "LIMIT\t#{head}\t#{hex}\tutf8\t#{e.message.include?('memory') ? 'memory' : 'time'}"
          next
        rescue ArgumentError => e
          if e.message.include?("UTF-8")
            c.right += 1
          else
            c.errors += 1
            w << "ERROR\t#{head}\t#{hex}\tutf8\t#{e.class}: #{e.message}"
          end
          next
        end
        c.wrong += 1
        w << "WRONG\t#{head}\t#{hex}\tutf8\tread as UTF-8 (#{got}), not refused"
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
      # One match more than the data has: wrong, unless the data kept only the first twenty.
      return all.length == 20 if n >= all.length
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
      if n >= all.length
        ok &&= all.length == 20
        break
      end

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

  EXEC = "exec/test262.jsonl"

  # A call's lastIndex. Past the end of the text exec gives null; test262 sets it as far as 2^53 - 1 and
  # Number.MAX_VALUE, so anything past the end reads as the text's length plus one.
  def last_index_of(t, length)
    v = t["lastIndex"]
    v > length ? length + 1 : v.to_i
  end

  # Whether a position is between the halves of a surrogate pair, where UTF-8 has no position.
  def inside_pair?(u, at) = at.positive? && at < u.length && u[at].between?(0xDC00, 0xDFFF) && u[at - 1].between?(0xD800, 0xDBFF)

  # Whether a match (nil for none) is the call's answer: both null, or the same groups, the same named groups (present
  # exactly when the pattern has names) and, with g or y, a lastIndex after at the match's end. map takes the answer's
  # UTF-16 positions to the match's, and bytes reads the match in bytes.
  def same_exec?(answer, m, names, carries, map, bytes)
    return answer.nil? && m.nil? if answer.nil? || m.nil?

    at = ->(g) { bytes ? m.byteoffset(g) : m.offset(g) }
    span = ->(e) { e.nil? ? [nil, nil] : [map[e[0]], map[e[1]]] }
    captures = answer["captures"]
    return false unless captures.length == m.size && captures.each_with_index.all? { |e, g| at.call(g) == span.call(e) }

    groups = answer["groups"]
    if groups.nil?
      return false unless names.empty?
    else
      return false unless groups.keys.sort == names.sort && groups.all? { |n, e| at.call(n) == span.call(e) }
    end
    !carries || map[answer["lastIndex"]] == at.call(0)[1]
  end

  # A record of exec/test262.jsonl: the pattern with its own flags (g, y and d among them), from each call's lastIndex.
  def judge_exec(r, pattern, c, w)
    flags = r["flags"].to_s
    re, why, = compile(pattern, flags)
    if re.nil?
      c.refused += 1
      w << "REFUSED\t#{EXEC}\t/#{shown(pattern)}/#{flags}\t#{why}"
      return
    end
    carries = flags.include?("g") || flags.include?("y")
    (r["tests"] || []).each do |t|
      next if t["v8_deviation"]

      text = t["text"]
      u = units(text)
      start = carries ? last_index_of(t, u.length) : 0
      where = "/#{shown(pattern)}/#{flags}\t#{escape(text)}\t#{t["lastIndex"]}"
      runs = [["utf16", utf16(text), start, (0..u.length).to_a, false]]
      unless lone?(text) || inside_pair?(u, start)
        # A UTF-8 string's positions are characters: those before lastIndex.
        chars = start > u.length ? text.length + 1 : u[0, start].count { |x| !x.between?(0xDC00, 0xDFFF) }
        runs << ["utf8", text, chars, byte_offsets(text), true]
      end
      runs.each do |encoding, subject, pos, map, bytes|
        begin
          m = start > u.length ? nil : re.match(subject, pos, timeout: LIMIT)
        rescue R::MatchLimitError
          c.limited += 1
          w << "LIMIT\t#{EXEC}\t#{where}\t#{encoding}"
          next
        end
        if same_exec?(t["answer"], m, re.names, carries, map, bytes)
          c.right += 1
        else
          c.wrong += 1
          w << "WRONG\t#{EXEC}\t#{where}\t#{encoding}"
        end
      end
    end
  end

  # The engine's compliance as the benchmark page reads it: the counts, this runner and the calls it makes in each
  # encoding, and what it leaves out.
  def write_compliance(path, total)
    File.write(path, "#{JSON.generate({
      "right" => total.right, "wrong" => total.wrong, "refused" => total.refused, "acceptedInvalid" => total.accepted,
      "limited" => total.limited + total.errors,
      "judge" => {
        "runner" => "https://github.com/corvus-dotnet/corvus-regex-ecma262-ruby/blob/main/tools/dataset.rb",
        "calls" => {
          "utf16" => %w[match? match each_match replace replace_all split].map { |m| "Regex##{m}(UTF-16LE String)" },
          "utf8" => %w[match? match each_match replace replace_all].map { |m| "Regex##{m}(UTF-8 String)" }
        }
      },
      "excludes" => []
    })}\n")
  end

  def judge_lines(name, lines)
    c = Counts.zero
    w = []
    records = skipped = 0
    lines.each do |line|
      next if line.strip.empty?

      r = read(line)
      if r["v8_deviation"]
        skipped += 1
        next
      end
      records += 1
      pattern = r["pattern"]
      next if pattern.nil?

      case name
      when EXEC then judge_exec(r, pattern, c, w)
      when "captures.jsonl" then judge_captures(r, pattern, c, w)
      when "ill-formed-utf8.jsonl" then judge_ill_formed(r, pattern, c, w)
      else judge_tests(name, r, pattern, c, w)
      end
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
    abort "usage: ruby -Ilib tools/dataset.rb <data directory> <wrong-cases file> [--files glob] [--workers N] " \
          "[--compliance file]" unless wrong_path
    files_glob = "*.jsonl"
    workers = 4
    compliance = nil
    rest.each_slice(2) do |flag, value|
      case flag
      when "--files" then files_glob = value
      when "--workers" then workers = Integer(value)
      when "--compliance" then compliance = value
      else abort "unknown option #{flag}"
      end
    end
    files = Dir.children(data).select { |f| f.end_with?(".jsonl") && File.fnmatch(files_glob, f) }.sort
    # The exec calls of test262, in a directory of their own: with the default filter, or one that names them.
    files << EXEC if (files_glob == "*.jsonl" || files_glob.start_with?("exec")) && File.file?(File.join(data, EXEC))
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
    write_compliance(compliance, total) if compliance
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    puts format("\nrecords %d (skipped %d deviations)  right %d  wrong %d  refused-valid %d  accepted-invalid %d  " \
                "limit %d  errors %d  in %.1fs", records, skipped, total.right, total.wrong, total.refused, total.accepted,
                total.limited, total.errors, elapsed)
    total.wrong + total.refused + total.accepted + total.errors + total.limited
  end
end

exit(Dataset.main(ARGV).zero? ? 0 : 1) if $PROGRAM_NAME == __FILE__
