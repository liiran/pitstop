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
puts out.lines.grep(/pitstop|Pitstop|runs,|examples,/i).join
puts "record: exit #{code} in #{seconds}s"
abort "record failed" unless File.exist?(".pitstop/map.json.gz")

# Tests already failing when the map was made always run, and fail again: a run whose only
# failures are those passes.
map = Zlib::GzipReader.open(".pitstop/map.json.gz") { JSON.parse(_1.read) }
baseline = map["tests"].count { _1[3] == "fail" }
puts "already failing before any change: #{baseline}"

rows = File.readlines(list, chomp: true).reject { _1.strip.empty? || _1.start_with?("#") }.map do |line|
  label, path, from, to, expected = line.split(" | ").map(&:strip)
  to = to.gsub("\\n", "\n")
  source = File.read(path)
  abort "#{path}: #{from.inspect} not found" unless source.include?(from)
  File.write(path, source.sub(from, to))
  begin
    out, code, seconds = sh(*pitstop, "run", *(["--", *record_command] unless record_command.empty?))
    picked = out[/^(?:Running|Would run) (.*)$/, 1] || out[/^Nothing to run.*$/] || "?"
    checked = out[/^Pitstop: ran .*$/] || "-"
    framework = out.scan(/^(\d+) (?:runs|examples),/).flatten.map(&:to_i).sum
    failures = out.scan(/(\d+) (?:failures|errors)/).flatten.map(&:to_i).sum
    outcome = case code
              when 0 then out.include?("Nothing to run") ? "nothing" : "pass"
              when 1 then failures <= baseline ? "pass" : "fail"
              else "pitstop error #{code}"
              end
    problems = out.lines.grep(/^pitstop: /).map(&:strip)
    ok = outcome == expected && problems.none? { _1.include?("didn't run") || _1.include?("no tests ran") }
    puts "#{ok ? 'OK  ' : 'BAD '} #{label}: #{picked} | #{checked} | framework ran #{framework} | #{outcome} in #{seconds}s"
    problems.each { puts "     #{_1}" }
    puts out unless ok
    [label, picked, checked, framework, outcome, expected, seconds, ok]
  ensure
    File.write(path, source)
  end
end

puts "\n#{rows.count(&:last)} of #{rows.size} scenarios as expected"
