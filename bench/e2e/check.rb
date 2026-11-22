# End-to-end check on a real app: `pitstop record` once, then for each scenario make one change,
# `pitstop run`, and report what it picked, how many tests the framework ran, and whether the run
# ended the way it should (`pass`: the change keeps behaviour, `fail`: a planted bug the selection
# must catch, `nothing`: no test can be affected).
#
#   ruby bench/e2e/check.rb <app dir> <scenarios file> [-- record command]
#
# Scenario lines: label | path | text to replace | replacement | expected
require "open3"
require "json"
require "zlib"

app, list, *rest = ARGV
record_command = rest.first == "--" ? rest.drop(1) : []
pitstop = [Gem.ruby, File.expand_path("../../exe/pitstop", __dir__)]
Dir.chdir(app)

def sh(*command)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  out, status = Open3.capture2e(*command)
  [out, status.exitstatus, (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1)]
end

out, code, seconds = sh(*pitstop, "record", *(["--", *record_command] unless record_command.empty?))
puts out.lines.grep(/pitstop|Pitstop|runs,|tests,|examples,/i).join
puts "record: exit #{code} in #{seconds}s"
abort "record failed" unless File.exist?(".pitstop/map.json.gz")

# The whole suite without Pitstop, in the same session, to compare run times with. (After the
# recording, so both start with warm caches.)
if (plain = ENV["PLAIN_COMMAND"])
  _, plain_code, plain_seconds = sh(*plain.split)
  puts "whole suite without Pitstop (`#{plain}`): exit #{plain_code} in #{plain_seconds}s"
end

# Tests already failing when the map was made always run, and fail again: a run whose only
# failures are those passes.
map = Zlib::GzipReader.open(".pitstop/map.json.gz") { JSON.parse(_1.read) }
baseline = map["tests"].count { _1[3] == "fail" }
puts "already failing before any change: #{baseline}"
# How long each test took while the map was recorded (coverage on, so slower than a plain run,
# but the same for every test): a selection's share of that is its share of the suite's time.
ms = map["tests"].to_h { [_1[0], _1[4].to_f] }
total_ms = ms.values.sum
puts "tests' own time in the map: #{(total_ms / 1000).round(1)}s"

# The selected tests' share of the suite's own test time, from `pitstop list --json`.
def time_share(json, map, ms, total_ms)
  picked = json["run_all"] ? map["tests"].map(&:first) : json["tests"] + map["tests"].select { json["files"].include?(_1[1]) }.map(&:first)
  sum = picked.uniq.sum { ms.fetch(_1, 0) }
  "test time #{(sum / 1000).round(1)}s of #{(total_ms / 1000).round(1)}s (#{(100 * sum / total_ms).round(1)}%)"
end

rows = File.readlines(list, chomp: true).reject { _1.strip.empty? || _1.start_with?("#") }.map do |line|
  label, path, from, to, expected = line.split(" | ").map(&:strip)
  to = to.gsub("\\n", "\n")
  source = File.read(path)
  abort "#{path}: #{from.inspect} not found" unless source.include?(from)
  File.write(path, source.sub(from, to))
  begin
    listed, _, picking = sh(*pitstop, "list", "--json")
    share = begin
      time_share(JSON.parse(listed[/^\{.*\}/m]), map, ms, total_ms)
    rescue StandardError => e
      "test time unknown (#{e.class})"
    end
    out, code, seconds = sh(*pitstop, "run", *(["--", *record_command] unless record_command.empty?))
    picked = out[/^(?:Running|Would run) (.*)$/, 1] || out[/^Nothing to run.*$/] || "?"
    checked = out[/^Pitstop: ran .*$/] || "-"
    framework = out.scan(/^(\d+) (?:runs|tests|examples),/).flatten.map(&:to_i).sum
    failures = out.scan(/(\d+) (?:failures|errors)/).flatten.map(&:to_i).sum
    outcome = case code
              when 0 then out.include?("Nothing to run") ? "nothing" : "pass"
              when 1 then failures <= baseline ? "pass" : "fail"
              else "pitstop error #{code}"
              end
    problems = out.lines.grep(/^pitstop: /).map(&:strip)
    ok = outcome == expected && problems.none? { _1.include?("didn't run") || _1.include?("no tests ran") }
    # What the framework says the run took, and (RSpec) how long loading the files took.
    took = out[/^Finished in .*$/]&.strip || "-"
    puts "#{ok ? 'OK  ' : 'BAD '} #{label}: #{picked} | #{checked} | framework ran #{framework} | #{outcome} in #{seconds}s"
    puts "     #{share} | #{took} | picking took #{picking}s"
    problems.each { puts "     #{_1}" }
    puts out unless ok
    [label, picked, checked, framework, outcome, expected, seconds, ok]
  ensure
    File.write(path, source)
  end
end

puts "\n#{rows.count(&:last)} of #{rows.size} scenarios as expected"
