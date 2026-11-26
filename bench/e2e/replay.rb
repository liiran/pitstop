# Replays an app's real history, one commit at a time. For each of its last N commits on the main
# branch:
#
#   1. the map is the one recorded at the commit before it
#   2. at the commit, `pitstop run` is timed next to the whole suite without Pitstop
#   3. the commit is recorded in turn, which also says which tests fail there: a test that started
#      failing at this commit and wasn't picked is a miss
#
#   ruby bench/e2e/replay.rb <app dir> <results.jsonl> <N> [-- test command]
#
# One JSON line per commit is added to the results file as it goes; commits already there are
# skipped, so a stopped replay can be started again.
#
# Environment:
#   PLAIN_COMMAND  the whole suite without Pitstop (required)
#   SETUP          a shell line run after every checkout (install gems, prepare the database)
#   UNTIL          replay the N commits ending at this commit instead of the checked-out one
#   SKIP_RUN_ALL   1: when Pitstop picks everything, don't run the suite a second time. Its time
#                  is then counted as the whole suite's plus the picking, which is what
#                  `pitstop run` does in that case.
#   MAPS           keep every commit's map in this folder
#   RETIME         1: time the commits already in the results file once more, from the kept maps
#   ONLY           with RETIME, only these commits (ids separated by commas)
#   RECORD_ONLY    1: record the map at the commit before each of the N commits and keep it in
#                  MAPS, nothing else. For after a change to what the recorder writes: reselect.rb
#                  then asks Pitstop again from the new maps.
require "fileutils"
require_relative "bench"

app, out_path, count, *rest = ARGV
command = rest.first == "--" ? rest.drop(1) : []
tail = command.empty? ? [] : ["--", *command]
plain = ENV.fetch("PLAIN_COMMAND").split
setup = ENV["SETUP"]
Dir.chdir(app)
MAP = ".pitstop/map.json.gz"

class Skip < StandardError; end

def checkout(sha)
  system("git", "checkout", "-q", "-f", "--detach", sha) or raise Skip, "couldn't check out #{sha[0, 7]}"
  system("git", "clean", "-fdq") # untracked files a test run left; ignored ones (caches, .pitstop/) stay
end

# Gems and the database for the commit now checked out. It must leave the checkout as committed:
# a lockfile rewritten here would look like a change to Pitstop.
def prepare(setup, sha)
  raise Skip, "setup failed at #{sha[0, 7]}" if setup && !system("sh", "-c", setup)

  dirty = Bench.git("status", "--porcelain").lines.map(&:strip)
  raise Skip, "setup changed files at #{sha[0, 7]}: #{dirty.first(3).join(', ')}" unless dirty.empty?
end

def record(tail)
  FileUtils.rm_f(MAP)
  out, code, seconds = Bench.sh(*Bench::PITSTOP, "record", *tail)
  unless File.exist?(MAP)
    raise Skip, "recording failed (exit #{code}): #{out.lines.grep(/^pitstop: /).last.to_s.strip}"
  end
  [Bench.map, seconds, code]
end

def keep(map_dir, sha)
  return unless map_dir

  FileUtils.mkdir_p(map_dir)
  FileUtils.cp(MAP, File.join(map_dir, "#{sha}.json.gz"))
end

tip = ENV["UNTIL"] || Bench.git("rev-parse", "HEAD")
start = Bench.git("rev-parse", "HEAD")
commits = Bench.git("rev-list", "--first-parent", "--reverse", "-n", count, tip).lines.map(&:strip)
done = File.exist?(out_path) ? File.readlines(out_path).map { JSON.parse(_1)["sha"] } : []
map = nil

if ENV["RECORD_ONLY"] == "1"
  begin
    commits.map { Bench.git("rev-parse", "#{_1}^1") }.uniq.each do |sha|
      next if Dir[File.join(ENV.fetch("MAPS"), "#{sha}*.json.gz")].any?

      checkout(sha)
      prepare(setup, sha)
      _, seconds, = record(tail)
      keep(ENV.fetch("MAPS"), sha)
      puts "#{sha[0, 9]} recorded in #{seconds}s"
    rescue Skip => e
      puts "#{sha[0, 9]} not recorded: #{e.message}"
    end
  ensure
    system("git", "checkout", "-q", "-f", "--detach", start)
  end
  exit
end

# RETIME=1: time the commits already in the results file once more, with the maps kept from the
# first pass (so nothing is recorded again). A machine that is busy for a moment makes one run
# slow; with two timings of each side, the report can take the better one of each.
if ENV["RETIME"] == "1"
  rows = File.readlines(out_path).map { JSON.parse(_1) }
  begin
    commits.each_with_index do |sha, i|
      row = rows.find { sha.start_with?(_1["sha"]) && !_1["error"] } or next
      next if ENV["ONLY"] && ENV["ONLY"].split(",").none? { sha.start_with?(_1) }

      parent_map = Dir[File.join(ENV.fetch("MAPS"), "#{row['parent']}*.json.gz")].first or next
      checkout(sha)
      prepare(setup, sha)
      FileUtils.mkdir_p(".pitstop")
      File.write(".pitstop/.gitignore", "*\n")
      FileUtils.cp(parent_map, MAP)
      (i.even? ? %i[plain pitstop] : %i[pitstop plain]).each do |step|
        if step == :plain then (row["plain_again"] ||= []) << Bench.sh(*plain)[2]
        elsif row["run_measured"] then (row["run_again"] ||= []) << Bench.sh(*Bench::PITSTOP, "run", *tail)[2]
        end
      end
      File.write(out_path, rows.map { "#{JSON.generate(_1)}\n" }.join)
      puts "#{row['sha']} again: #{row['run_again']&.last || '-'}s instead of #{row['plain_again'].last}s " \
           "(first time #{row['run_s']}s instead of #{row['plain_s']}s)"
    rescue Skip => e
      puts "#{sha[0, 9]} not timed again: #{e.message}"
    end
  ensure
    system("git", "checkout", "-q", "-f", "--detach", start)
  end
  exit
end

begin
  commits.each_with_index do |sha, i|
    next if done.any? { sha.start_with?(_1) }

    parent = Bench.git("rev-parse", "#{sha}^1")
    row = { app: File.basename(app), sha: sha[0, 9], parent: parent[0, 9],
            date: Bench.git("show", "-s", "--format=%cs", sha), time: Bench.git("show", "-s", "--format=%ct", sha).to_i,
            subject: Bench.git("show", "-s", "--format=%s", sha),
            files_changed: Bench.git("diff", "--name-only", parent, sha).lines.size,
            load_average: Bench.load_average }
    begin
      unless map && map["commit"] == parent
        checkout(parent)
        prepare(setup, parent)
        map, seconds, = record(tail)
        keep(ENV["MAPS"], parent)
        puts "#{parent[0, 9]} recorded in #{seconds}s (the map for #{sha[0, 9]})"
      end
      before = map

      checkout(sha)
      prepare(setup, sha)
      listed, _, pick_s = Bench.sh(*Bench::PITSTOP, "list", "--json")
      json = Bench.selection(listed)
      ids = Bench.selected_ids(json, before)
      # Tests that failed or were skipped when the map was made run whatever the change is.
      always = before["tests"].select { _1[3] != "pass" }.map(&:first)
      row.merge!(picked: if json["run_all"] then "all"
                         elsif ids.empty? && json["files"].empty? then "nothing"
                         elsif json["files"].empty? && (ids - always).empty? then "only the tests that always run"
                         else "some"
                         end,
                 why_all: json["run_all"], pick_s:, share_of_test_time: Bench.share_of_test_time(ids, before))

      # Alternate which goes first, so neither side always gets the warmer caches.
      steps = i.even? ? %i[pitstop plain] : %i[plain pitstop]
      steps.each do |step|
        if step == :plain
          _, row[:plain_exit], row[:plain_s] = Bench.sh(*plain)
        elsif json["run_all"] && ENV["SKIP_RUN_ALL"] == "1"
          row[:run_measured] = false
        else
          out, row[:run_exit], row[:run_s] = Bench.sh(*Bench::PITSTOP, "run", *tail)
          row[:run_measured] = true
          row[:tests_run] = json["run_all"] ? Bench.framework_ran(out) : Bench.pitstop_ran(out).to_i
          row[:problems] = out.lines.grep(/^pitstop: /).map(&:strip).first(3)
        end
      end
      row[:run_s] ||= (row[:plain_s] + pick_s).round(2)

      map, row[:record_s], = record(tail)
      keep(ENV["MAPS"], sha)
      row[:tests] = map["tests"].size
      row[:tests_run] ||= row[:tests]
      # Tests that fail here and passed (or didn't exist) at the commit before. Every one of them
      # has to be among the picked tests, or in a test file picked whole.
      passed_before = before["tests"].to_h { [_1[0], _1[3] == "pass"] }
      new_failures = map["tests"].select { _1[3] == "fail" && passed_before.fetch(_1[0], true) }
      row[:new_failures] = new_failures.map(&:first)
      row[:missed] = json["run_all"] ? [] : new_failures.reject { ids.include?(_1[0]) || json["files"].include?(_1[1]) }.map(&:first)
    rescue Skip => e
      row[:error] = e.message
      map = nil
    end

    File.write(out_path, JSON.generate(row) + "\n", mode: "a")
    puts "#{row[:sha]} #{row[:subject][0, 60]}: " +
         (row[:error] || "picked #{row[:picked]}, #{row[:tests_run]} of #{row[:tests]} tests, " \
                         "#{row[:run_s]}s instead of #{row[:plain_s]}s (record #{row[:record_s]}s)" \
                         "#{", MISSED #{row[:missed].size}" unless row[:missed].empty?}")
  end
ensure
  system("git", "checkout", "-q", "-f", "--detach", start)
end
