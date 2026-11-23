# One change at a time on a real app: what Pitstop picks, whether the run ends the way it should,
# and how long it takes next to the whole suite.
#
#   ruby bench/e2e/check.rb <app dir> <changes file> [-- test command]
#
# Lines of the changes file:  label | path | text to replace | replacement | expected
#   expected: `pass` (the change keeps behaviour), `fail` (a planted bug the selection must catch)
#             or `nothing` (no test can be affected)
#   text to replace: some text in the file, or `(append)` to add the replacement at its end,
#             or `(new file)`
#
# Environment:
#   PLAIN_COMMAND  the whole suite without Pitstop, timed to compare with
#   ROUNDS         how many times to time the suite and every change (default 1)
#   RECORDS        how many times to time `pitstop record` (default 1)
#   OUT            write the numbers to this file as JSON
require_relative "bench"

app, list, *rest = ARGV
command = rest.first == "--" ? rest.drop(1) : []
tail = command.empty? ? [] : ["--", *command]
rounds = Integer(ENV.fetch("ROUNDS", "1"))
plain = ENV["PLAIN_COMMAND"]&.split
Dir.chdir(app)
load_before = Bench.load_average

Change = Struct.new(:label, :path, :from, :to, :expected)
changes = File.readlines(list, chomp: true).reject { _1.strip.empty? || _1.start_with?("#") }.map do |line|
  label, path, from, to, expected = line.split(" | ").map(&:strip)
  Change.new(label, path, from, to.gsub("\\n", "\n"), expected)
end

# Makes the change, yields, and puts the file back as it was.
def with_change(change)
  existed = File.exist?(change.path)
  source = File.binread(change.path) if existed
  case change.from
  when "(new file)"
    abort "#{change.path} already exists" if existed
    File.binwrite(change.path, change.to)
  when "(append)"
    File.binwrite(change.path, source + change.to)
  else
    abort "#{change.path}: #{change.from.inspect} not found" unless source&.include?(change.from)
    File.binwrite(change.path, source.sub(change.from) { change.to })
  end
  yield
ensure
  if existed then File.binwrite(change.path, source)
  elsif File.exist?(change.path) then File.delete(change.path)
  end
end

# Once before timing anything, so every timed run starts with the same warm caches.
if plain && rounds > 1
  _, code, seconds = Bench.sh(*plain)
  puts "warm-up, not counted (`#{plain.join(' ')}`): exit #{code} in #{seconds}s"
end

record_times = Integer(ENV.fetch("RECORDS", "1")).times.map do
  out, code, seconds = Bench.sh(*Bench::PITSTOP, "record", *tail)
  puts out.lines.grep(/pitstop|Pitstop|runs,|tests,|examples,/i).join
  puts "record: exit #{code} in #{seconds}s"
  seconds
end
abort "record failed" unless File.exist?(".pitstop/map.json.gz")

# Tests already failing when the map was made always run, and fail again: a run whose only
# failures are those passes.
map = Bench.map
baseline = map["tests"].count { _1[3] == "fail" }
puts "already failing before any change: #{baseline}"

plain_times = []
plain_code = nil
rows = changes.map { { label: _1.label, path: _1.path, expected: _1.expected, ok: true, pick_s: [], run_s: [] } }

rounds.times do |round|
  if plain
    # The whole suite without Pitstop, in the same session, once per round so that a machine
    # getting busier or quieter shows up on both sides.
    _, plain_code, seconds = Bench.sh(*plain)
    plain_times << seconds
    puts "whole suite without Pitstop (`#{plain.join(' ')}`): exit #{plain_code} in #{seconds}s"
  end

  changes.each_with_index do |change, i|
    with_change(change) do
      listed, _, picking = Bench.sh(*Bench::PITSTOP, "list", "--json")
      json = Bench.selection(listed)
      ids = Bench.selected_ids(json, map)
      out, code, seconds = Bench.sh(*Bench::PITSTOP, "run", *tail)

      picked = out[/^(?:Running|Would run) (.*)$/, 1] || out[/^Nothing to run.*$/] || "?"
      checked = out[/^Pitstop: ran .*$/] || "-"
      framework = Bench.framework_ran(out)
      failures = out.scan(/(\d+) (?:failures|errors)/).flatten.sum(&:to_i)
      outcome = case code
                when 0 then out.include?("Nothing to run") ? "nothing" : "pass"
                when 1 then failures <= baseline ? "pass" : "fail"
                else "pitstop error #{code}"
                end
      problems = out.lines.grep(/^pitstop: /).map(&:strip)
      ok = outcome == change.expected && problems.none? { _1.include?("didn't run") || _1.include?("no tests ran") }
      share = Bench.share_of_test_time(ids, map)
      # What the framework says the run took, and (RSpec) how long loading the files took.
      took = out[/^Finished in .*$/]&.strip || "-"

      puts "#{ok ? 'OK  ' : 'BAD '} #{change.label}: #{picked} | #{checked} | framework ran #{framework} | #{outcome} in #{seconds}s"
      puts "     #{share}% of the suite's test time | #{took} | picking took #{picking}s"
      problems.each { puts "     #{_1}" }
      puts out unless ok

      row = rows[i]
      row[:ok] &&= ok
      row[:pick_s] << picking
      row[:run_s] << seconds
      row.merge!(outcome:, run_all: json["run_all"], tests_run: json["run_all"] ? framework : Bench.pitstop_ran(out).to_i,
                 share_of_test_time: share)
    end
  end
  puts "round #{round + 1} of #{rounds} done" if rounds > 1
end

good = rows.count { _1[:ok] }
puts "\n#{good} of #{rows.size} changes as expected"

if (out_path = ENV["OUT"])
  File.write(out_path, JSON.pretty_generate(
    app: File.basename(app), commit: Bench.git("rev-parse", "--short", "HEAD"), date: Time.now.utc.strftime("%Y-%m-%d"),
    machine: Bench.machine, load_average: [load_before, Bench.load_average],
    command: command.empty? ? "(the default)" : command.join(" "), plain_command: plain&.join(" "), plain_exit: plain_code,
    rounds:, tests: map["tests"].size, already_failing: baseline,
    plain_s: plain_times, record_s: record_times, map_kb: (File.size(".pitstop/map.json.gz") / 1024.0).round,
    changes: rows
  ) + "\n")
  puts "saved #{out_path}"
end
exit(good == rows.size ? 0 : 1)
