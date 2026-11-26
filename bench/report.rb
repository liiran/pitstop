# Rewrites the tables in bench/RESULTS.md from the numbers in bench/results/:
#
#   ruby bench/report.rb
#
# Each table sits between two marker lines, <!-- name --> and <!-- /name -->, and only the text
# between them is replaced. A table whose numbers aren't there yet is left alone.
require "json"

RESULTS = File.expand_path("results", __dir__)
PAGE = File.expand_path("RESULTS.md", __dir__)
NAMES = { "fizzy" => "Fizzy", "rubocop" => "RuboCop", "deadheat" => "Dead Heat" }.freeze

def median(numbers)
  sorted = numbers.compact.sort
  mid = sorted.size / 2
  sorted.size.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
end

def mean(numbers) = numbers.sum.to_f / numbers.size

def seconds(s) = s >= 100 ? "#{s.round} s" : format("%.1f s", s)

def minutes(s) = s >= 120 ? format("%.1f min", s / 60.0) : seconds(s)

def count(n) = n.to_s.reverse.scan(/\d{1,3}/).join(",").reverse

def percent(part, whole)
  value = whole.zero? ? 0 : part * 100.0 / whole
  return "under 0.1%" if value.positive? && value < 0.05

  format(value.positive? && value < 10 ? "%.1f%%" : "%.0f%%", value)
end

def faster(before, after)
  ratio = before / after
  if ratio >= 10 then "#{ratio.round}× faster"
  elsif ratio >= 1.05 then format("%.1f× faster", ratio)
  elsif ratio > 0.95 then "the same"
  else "#{((1 / ratio - 1) * 100).round}% slower"
  end
end

def change(before, after)
  share = (after - before) * 100.0 / before
  share.abs < 0.5 ? "the same" : "#{share.abs.round}% #{share.negative? ? 'less' : 'more'}"
end

def table(header, rows)
  ["| #{header.join(' | ')} |", "|#{header.map { '---' }.join('|')}|", *rows.map { "| #{_1.join(' | ')} |" }].join("\n")
end

def changes(app) = File.exist?(path = File.join(RESULTS, "#{app}-changes.json")) ? JSON.parse(File.read(path)) : nil

def lines(name) = File.exist?(path = File.join(RESULTS, name)) ? File.readlines(path).map { JSON.parse(_1) } : nil

# The commits that could be replayed, oldest first. A commit timed more than once counts with the
# best time of each side: a machine that is busy for a moment only ever makes a run slower. When
# Pitstop picked everything and that run was skipped, its time is the whole suite's plus the picking.
def replay(app, file = "#{app}-replay.jsonl")
  lines(file)&.reject { _1["error"] }&.sort_by { _1["time"] }&.map do |row|
    plain = [row["plain_s"], *row["plain_again"]].min
    run = row["run_measured"] ? [row["run_s"], *row["run_again"]].min : plain + row["pick_s"]
    # No change a test could be affected by, so only the tests that always run ran (those that
    # failed or were skipped when the map was made): counted with the commits that picked nothing.
    always = row["picked"] == "only the tests that always run"
    row.merge("plain_s" => plain, "run_s" => run, "picked" => always ? "nothing" : row["picked"], "always" => always)
  end
end

# One change at a time: the whole suite next to `pitstop run`, smallest selection first.
def changes_table(app)
  data = changes(app) or return
  before = median(data["plain_s"])
  rows = data["changes"].sort_by { [_1["tests_run"], median(_1["run_s"])] }.map do |c|
    after = median(c["run_s"])
    tests = c["tests_run"].zero? ? "none" : "#{count(c['tests_run'])} of #{count(data['tests'])} (#{percent(c['tests_run'], data['tests'])})"
    [c["label"].sub(/\A./, &:upcase), tests, seconds(before), seconds(after), faster(before, after)]
  end
  table(["What changed", "Tests run", "Whole suite", "With Pitstop", "Difference"], rows)
end

# Real commits: what the whole history replayed adds up to.
def replay_summary(app)
  rows = replay(app) or return
  before = rows.sum { _1["plain_s"] }
  after = rows.sum { _1["run_s"] }
  by = rows.group_by { _1["picked"] }
  part = ->(kind) { "#{by.fetch(kind, []).size} of #{rows.size}" }
  some = by.fetch("some", [])
  table(["", NAMES.fetch(app)], [
    ["Commits replayed", "#{rows.size} (#{rows.first['date']} to #{rows.last['date']})"],
    ["Changed nothing a test can be affected by: ran no tests, or only the few that always run", part.("nothing")],
    ["Ran some of the tests", part.("some") + (some.empty? ? "" : ", half of them under #{percent(median(some.map { _1['tests_run'].to_f / _1['tests'] }), 1)} of the tests")],
    ["Ran everything (a library update, a settings file, a file the map can't follow)", part.("all")],
    ["Whole suite, every commit", minutes(before)],
    ["`pitstop run`, every commit", "#{minutes(after)} (#{percent(before - after, before)} less)"],
    ["Average of each commit's time, as a share of the whole suite", percent(mean(rows.map { _1["run_s"] / _1["plain_s"] }), 1)],
    ["Recording, next to a plain run", format("%.2f×", recording_cost(app) || median(rows.map { _1["record_s"] / _1["plain_s"] }))],
    ["Tests that started failing at a commit", rows.sum { _1["new_failures"].size }.to_s],
    ["... of those, not picked", rows.sum { _1["missed"].size }.to_s]
  ])
end

def replay_commits(app)
  rows = replay(app) or return
  commits = table(["Commit", "What it was", "Pitstop picked", "Whole suite", "With Pitstop"], rows.reverse.map do |r|
    picked = case r["picked"]
             when "nothing" then r["always"] ? "only the #{r['tests_run']} tests that always run" : "nothing"
             when "all" then "everything: #{r['why_all'].to_s.delete_suffix(', so any test may depend on it')[0, 130]}"
             else "#{count(r['tests_run'])} of #{count(r['tests'])} tests"
             end
    subject = r["subject"].gsub("|", "/").then { _1.size > 64 ? "#{_1[0, 61]}..." : _1 }
    ["`#{r['sha'][0, 7]}`", subject, picked, seconds(r["plain_s"]), seconds(r["run_s"]) + (r["run_measured"] == false ? "*" : "")]
  end)
  return commits if rows.all? { _1["run_measured"] }

  "#{commits}\n\n\\* Not timed: when Pitstop runs everything, `pitstop run` is the whole suite plus the picking, so " \
    "that is the time counted (the whole suite's time at that commit, plus the #{seconds(median(rows.map { _1['pick_s'] }))} the picking took)."
end

# Test-step time per merged pull request: before, every run on the pull request and the one on
# the main branch run the whole suite; with Pitstop, the pull request's runs are `pitstop run`
# and the main branch's is `pitstop record`. Averages over the replayed commits.
# How many times a plain run `pitstop record` takes, timed with the recorder as it is now (the
# replayed commits were first recorded with an earlier one).
def recording_cost(app)
  data = changes(app) or return
  median(data["record_s"]) / median(data["plain_s"])
end

def ci_table
  apps = %w[fizzy rubocop].filter_map { |app| (rows = replay(app)) && [app, rows] }
  return if apps.empty?

  rows = [1, 2, 3, 5, 10].map do |runs|
    [runs.to_s, *apps.map do |app, commits|
      plain, run = %w[plain_s run_s].map { |key| mean(commits.map { _1[key] }) }
      record = plain * (recording_cost(app) || mean(commits.map { _1["record_s"] / _1["plain_s"] }))
      before = (runs + 1) * plain
      after = runs * run + record
      unit = before >= 120 ? ->(s) { format("%.1f min", s / 60.0) } : method(:seconds)
      "#{unit.(before)} → #{unit.(after)} (#{change(before, after)})"
    end]
  end
  table(["Test runs on a pull request before it merges", *apps.map { NAMES.fetch(_1.first) }], rows)
end

# What Pitstop would pick with a map that is some commits old (bench/e2e/stale.rb).
def stale_table
  apps = NAMES.keys.filter_map do |app|
    path = File.join(RESULTS, "#{app}-stale.json")
    [app, JSON.parse(File.read(path))["by_map_age"]] if File.exist?(path)
  end
  return if apps.empty?

  rows = apps.flat_map { _2.keys }.uniq.map do |age|
    [age == "1" ? "the commit before (recorded at every commit)" : "#{age} commits before", *apps.flat_map do |_, by_age|
      t = by_age[age]
      t ? ["#{t['ran_everything']} of #{t['commits']} commits", "#{t['mean_share_of_test_time'].round}%"] : %w[- -]
    end]
  end
  table(["The map is from", *apps.flat_map { ["#{NAMES.fetch(_1.first)}: ran everything at", "#{NAMES.fetch(_1.first)}: test time picked, on average"] }], rows)
end

def recording_table
  rows = NAMES.keys.filter_map do |app|
    data = changes(app) or next
    plain = median(data["plain_s"])
    record = median(data["record_s"])
    [NAMES[app], count(data["tests"]), seconds(plain), seconds(record), format("%.2f×", record / plain), "#{count(data['map_kb'])} KB"]
  end
  table(["", "Tests", "Whole suite", "`pitstop record`", "Cost", "Map file"], rows) unless rows.empty?
end

# Planted bugs, inside methods and outside them. "Caught" means `pitstop run` failed and, where
# the run checked each failing test (the "failing" count is there), that none was left out.
def mutants_table
  places = { "mutants" => "inside methods", "mutants-outside" => "outside methods" }
  rows = NAMES.keys.product(places.keys).filter_map do |app, file|
    list = lines("#{app}-#{file}.jsonl") or next
    catchable = list.reject { _1["caught_by"].start_with?("nothing") }
    tests = list.first.key?("failing") ? "#{count(catchable.sum { _1['left_out_count'] || _1['left_out'].size })} of #{count(catchable.sum { _1['failing'] })}" : "not counted"
    ["#{NAMES[app]}, #{places[file]}", list.size, list.size - catchable.size, catchable.size,
     "#{catchable.count { _1['caught_by'] == 'selection' }} of #{catchable.size}", tests]
  end
  header = ["Bugs planted", "How many", "Caught by no test", "Caught by the whole suite", "... of those, caught by `pitstop run`",
            "Failing tests left out"]
  table(header, rows) unless rows.empty?
end

# Files that tests read, emptied, deleted or joined by a new file, one at a time. Each change
# was picked for twice: as Pitstop does by default (the tests that read the file), and with
# `tests_after_readers: true` (also the tests that ran after a reader).
def read_files_table
  rows = NAMES.keys.filter_map do |app|
    tried = lines("#{app}-mutants-read.jsonl") or next
    # Where Pitstop ran everything no test can be left out: those were counted and not checked.
    list = tried.reject { _1["checked"] == false }
    next if list.empty?

    broke = list.reject { _1["caught_by"].start_with?("nothing") }
    failing = broke.sum { _1["failing"] }
    picked = ->(key) { list.map { _1[key] == "all" ? Float::INFINITY : _1[key] }.then { |n| median(n) }.then { _1.infinite? ? "everything" : count(_1.round) } }
    [NAMES[app], tried.size - list.size, list.size, list.size - broke.size, broke.size, count(failing),
     "#{count(broke.sum { _1['left_out_count'] })} of #{count(failing)}", "#{count(broke.sum { _1['left_out_after_readers_count'] })} of #{count(failing)}",
     picked.("picked"), picked.("picked_after_readers")]
  end
  header = ["Files changed", "Ran everything (not checked)", "Ran some tests (checked)", "... broke no test", "... broke a test", "Tests that failed", "... left out by default",
            "... left out with `tests_after_readers`", "Tests picked by default (median)", "... with `tests_after_readers` (median)"]
  table(header, rows) unless rows.empty?
end

# The replayed commits again with `tests_after_readers: true`. An app without a results file of
# its own for that setting had no commit that picks differently with it.
def after_readers_table
  rows = NAMES.keys.filter_map do |app|
    usual = replay(app) or next
    strict = replay(app, "#{app}-replay-after-readers.jsonl") || usual
    differ = usual.zip(strict).select { |a, b| a["picked"] != b["picked"] || a["tests_run"] != b["tests_run"] }
    total = ->(list) { before = list.sum { _1["plain_s"] }; after = list.sum { _1["run_s"] }; "#{minutes(after)} (#{percent(before - after, before)} less)" }
    tests = ->(list) { list.empty? ? "" : list.map { count(_1["tests_run"]) }.join(", ") }
    ["#{NAMES[app]}, #{usual.size} commits", "#{differ.size} of #{usual.size}", total.(usual), total.(strict), tests.(differ.map(&:first)), tests.(differ.map(&:last))]
  end
  header = ["", "Commits that pick differently", "`pitstop run`, every commit, by default", "... with `tests_after_readers`",
            "Tests run at those commits by default", "... with `tests_after_readers`"]
  table(header, rows) unless rows.empty?
end

blocks = { "recording" => recording_table, "planted-bugs" => mutants_table, "ci" => ci_table, "stale" => stale_table,
           "read-files" => read_files_table, "after-readers" => after_readers_table }
NAMES.each_key do |app|
  blocks["changes:#{app}"] = changes_table(app)
  blocks["replay:#{app}"] = replay_summary(app)
  blocks["commits:#{app}"] = replay_commits(app)
end

# Read and written as bytes, so the page keeps its line endings whatever system this runs on.
page = File.read(PAGE, mode: "rb", encoding: "UTF-8").delete("\r")
blocks.each do |name, text|
  next unless text

  marker = /(<!-- #{Regexp.escape(name)} -->\n).*?(<!-- \/#{Regexp.escape(name)} -->)/m
  warn "no place for #{name} in RESULTS.md" unless page.match?(marker)
  page = page.sub(marker) { "#{$1}#{text}\n#{$2}" }
end
File.write(PAGE, page, mode: "wb")
puts "updated #{PAGE}"
