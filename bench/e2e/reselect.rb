# After a change to what Pitstop picks: asks it again, at every replayed commit, with the map the
# replay kept for the commit before. Runs no tests, so it takes a minute and works outside the
# containers.
#
#   ruby bench/e2e/reselect.rb <app dir> <folder of kept maps> <results.jsonl>          show what would change
#   ruby bench/e2e/reselect.rb <app dir> <folder of kept maps> <results.jsonl> --save   and write it back
#
# With --save, a commit that now runs everything is counted with the whole suite's time plus the
# picking, which is what `pitstop run` does then (as with SKIP_RUN_ALL in replay.rb). A commit
# that now runs some of the tests, but not the ones it ran before, has no time to count: it is
# marked, and has to be timed again (replay.rb with RETIME=1 and ONLY).
#
# AFTER_READERS=1 asks with `tests_after_readers: true` (see pitstop_tests_after_readers.rb).
require "json"
require "zlib"
require "open3"
require "fileutils"

app, maps, results, save = ARGV
pitstop = [Gem.ruby, File.expand_path(ENV["AFTER_READERS"] == "1" ? "pitstop_tests_after_readers.rb" : "../../exe/pitstop", __dir__)]
git = ->(*args) { Open3.capture2("git", "-C", app, *args).then { |out, status| status.success? ? out.strip : abort("git #{args.join(' ')} failed") } }
start = git.("rev-parse", "HEAD")
rows = File.readlines(results).map { JSON.parse(_1) }
changed = 0

begin
  rows.each do |row|
    next if row["error"]

    map_path = Dir[File.join(maps, "#{row['parent']}*.json.gz")].first or abort "no kept map for #{row['parent']}"
    git.("checkout", "-q", "-f", "--detach", row["sha"])
    FileUtils.mkdir_p(File.join(app, ".pitstop"))
    File.write(File.join(app, ".pitstop", ".gitignore"), "*\n")
    FileUtils.cp(map_path, File.join(app, ".pitstop", "map.json.gz"))
    out, status = Open3.capture2(*pitstop, "list", "--json", chdir: app)
    abort "pitstop list failed at #{row['sha']}" unless status.success?

    json = JSON.parse(out)
    map = Zlib::GzipReader.open(map_path) { JSON.parse(_1.read) }
    always = map["tests"].select { _1[3] != "pass" }.map(&:first)
    ids = json["run_all"] ? map["tests"].map(&:first) : (json["tests"] + map["tests"].select { json["files"].include?(_1[1]) }.map(&:first)).uniq
    picked = if json["run_all"] then "all"
             elsif ids.empty? && json["files"].empty? then "nothing"
             elsif json["files"].empty? && (ids - always).empty? then "only the tests that always run"
             else "some"
             end
    was = [row["picked"], row["picked"] == "all" ? nil : row["tests_run"]]
    now = [picked, picked == "all" ? nil : ids.size]
    # The same kind of pick: different only if it is some of the tests, and another number of
    # them. (A row from before picks were counted has the number of tests that ran, which can
    # be more than were picked: a changed test file's new tests.)
    same = picked != "some" || (row["selected"] ? row["selected"] == ids.size : ids.size <= row["tests_run"])
    row["selected"] ||= ids.size if save && was[0] == now[0] && same
    next if was[0] == now[0] && same

    changed += 1 unless was[0] == now[0] && picked == "some"
    puts "#{row['sha'][0, 7]} #{row['subject'][0, 50].ljust(50)} #{was.compact.join(' ')} -> #{now.compact.join(' ')}#{"  (#{json['run_all'][0, 90]})" if json['run_all']}"
    next unless save

    row.merge!("picked" => picked, "why_all" => json["run_all"], "selected" => ids.size)
    if picked == "all"
      # Running everything is the whole suite: nothing new to time.
      row.merge!("run_measured" => false, "tests_run" => row["tests"], "share_of_test_time" => 100.0)
      row.delete("run_again")
    else
      row["needs_timing"] = true
      row.delete("run_again") # timings of the old pick
    end
  end
ensure
  git.("checkout", "-q", "-f", "--detach", start)
  FileUtils.rm_rf(File.join(app, ".pitstop"))
end

puts "#{changed} of #{rows.count { !_1['error'] }} commits pick differently now"
File.write(results, rows.map { "#{JSON.generate(_1)}\n" }.join, mode: "wb") if save
