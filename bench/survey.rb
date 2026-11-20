# Spike A: without running any tests, sort a repo's recent commits by what Pitstop's base rules
# would do with them. Tells us how often "run everything" would win before we build anything.
#
#   ruby bench/survey.rb bench/apps/fizzy [commits=1000]
require "json"
require "open3"
require_relative "../lib/pitstop/rules"

repo = ARGV.fetch(0)
limit = Integer(ARGV.fetch(1, 1000))
rules = Pitstop::Rules.new

log, status = Open3.capture2(
  "git", "-C", repo, "log", "--first-parent", "--diff-merges=first-parent", "--no-renames",
  "--name-status", "--format=@@%H %s", "-n", limit.to_s
)
abort "git log failed" unless status.success?

commits = log.split(/^@@/).reject(&:empty?).map do |chunk|
  head, *rows = chunk.lines.map(&:strip).reject(&:empty?)
  sha, subject = head.split(" ", 2)
  files = rows.to_h { |row| row.split("\t").then { |status, path| [path, status] } }
  { sha:, subject:, files: }
end.reject { |c| c[:files].empty? }

# With templates_followed, assume a changed template selects the tests that rendered it
# (what we get if templates show up in coverage); used to size that work before doing it.
def survey(commits, rules, templates_followed: false)
  commits.map do |c|
  verdicts = c[:files].to_h do |f, status|
    v = rules.classify(f)
    # A browser-only file can't change a Ruby test's result, unless it disappears.
    v = Pitstop::Rules::Verdict.new(:ignore, v.reason) if v.kind == :browser && status != "D"
    v = Pitstop::Rules::Verdict.new(:global, "browser-only file deleted") if v.kind == :browser
    v = Pitstop::Rules::Verdict.new(:ruby, v.reason) if templates_followed && v.reason.start_with?("template")
    [f, v]
  end
  kinds = verdicts.values.map(&:kind)
  outcome =
    if kinds.all?(:ignore) then "nothing to test"
    elsif kinds.include?(:global) then "run all: app-wide file"
    elsif kinds.include?(:other) then "run all: non-Ruby file"
    elsif kinds.reject { _1 == :ignore }.all?(:test) then "only test files"
    else "select from map"
    end
  blockers = verdicts.select { |_, v| %i[global other].include?(v.kind) }
  { **c, outcome:, blockers: blockers.transform_values { _1.reason } }
  end
end

results = survey(commits, rules)

def pct(n, total) = format("%5.1f%%", 100.0 * n / total)

total = results.size
puts "#{File.basename(File.expand_path(repo))}: #{total} first-parent commits"
results.group_by { _1[:outcome] }.sort_by { -_2.size }.each do |outcome, list|
  puts "  #{outcome.ljust(26)} #{list.size.to_s.rjust(5)}  #{pct(list.size, total)}"
end

run_all = results.select { _1[:outcome].start_with?("run all") }
puts "\nWhat forces 'run all' (commits where this kind of file appears):"
reasons = Hash.new(0)
run_all.each { |r| r[:blockers].values.uniq.each { reasons[_1] += 1 } }
reasons.sort_by { -_2 }.first(12).each { |reason, n| puts "  #{reason.ljust(40)} #{n.to_s.rjust(5)}  #{pct(n, total)}" }

puts "\nThe app-wide files hit most often:"
files = Hash.new(0)
run_all.each { |r| r[:blockers].each { |f, reason| files[f.sub(%r{/[^/]+\z}, "/…")] += 1 if reason == "app-wide file" } }
files.sort_by { -_2 }.first(10).each { |f, n| puts "  #{f.ljust(40)} #{n.to_s.rjust(5)}" }

puts "\nIf only one kind of blocker were handled, run-all commits that would become selectable:"
run_all.group_by { _1[:blockers].values.uniq }.select { _1.size == 1 }
       .map { |(reason), list| [reason, list.size] }.sort_by { -_2 }.first(8)
       .each { |reason, n| puts "  #{reason.ljust(40)} #{n.to_s.rjust(5)}  #{pct(n, total)}" }

following = survey(commits, rules, templates_followed: true)
n = following.count { _1[:outcome] == "select from map" }
puts "\nIf templates were followed: #{n} commits (#{pct(n, following.size).strip}) select from the map."

out = File.expand_path("out/survey-#{File.basename(File.expand_path(repo))}.json", __dir__)
Dir.mkdir(File.dirname(out)) unless Dir.exist?(File.dirname(out))
File.write(out, JSON.pretty_generate(results))
puts "\nDetails: #{out}"
