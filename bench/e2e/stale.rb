# How much does an old map cost? For every replayed commit, asks Pitstop what it would pick with
# the map from 1, 2, 3, 5 and 10 commits earlier, as when the map is recorded now and then (nightly,
# say) and not at every commit. Runs no tests: it uses the maps a replay kept (MAPS) and
# `pitstop list`, so it takes a minute and works outside the containers.
#
#   ruby bench/e2e/stale.rb <app dir> <folder of kept maps> <results.jsonl> <out.json>
#
# The "share of test time" is worked out from each test's time in the map, not timed again.
require "json"
require "zlib"
require "open3"
require "fileutils"

app, maps, results, out_path = ARGV
pitstop = [Gem.ruby, File.expand_path("../../exe/pitstop", __dir__)]
git = ->(*args) { Open3.capture2("git", "-C", app, *args).then { |out, status| status.success? ? out.strip : abort("git #{args.join(' ')} failed") } }
start = git.("rev-parse", "HEAD")

rows = File.readlines(results).map { JSON.parse(_1) }.sort_by { _1["time"] }
# The whole chain of commits, oldest first: the commit before the first replayed one, then each.
chain = git.("rev-list", "--first-parent", "--reverse", "#{rows.first['parent']}^..#{rows.last['sha']}").lines.map(&:strip)
map_of = ->(sha) { Dir[File.join(maps, "#{sha}*.json.gz")].first }

begin
  table = [1, 2, 3, 5, 10].to_h do |age|
    shares = chain.each_with_index.filter_map do |sha, i|
      next if i < age || !(map_path = map_of.(chain[i - age]))

      git.("checkout", "-q", "-f", "--detach", sha)
      FileUtils.mkdir_p(File.join(app, ".pitstop"))
      File.write(File.join(app, ".pitstop", ".gitignore"), "*\n")
      FileUtils.cp(map_path, File.join(app, ".pitstop", "map.json.gz"))
      out, status = Open3.capture2(*pitstop, "list", "--json", chdir: app)
      abort "pitstop list failed at #{sha[0, 9]}" unless status.success?

      json = JSON.parse(out)
      next 100.0 if json["run_all"]

      map = Zlib::GzipReader.open(map_path) { JSON.parse(_1.read) }
      ms = map["tests"].to_h { [_1[0], _1[4].to_f] }
      ids = (json["tests"] + map["tests"].select { json["files"].include?(_1[1]) }.map(&:first)).uniq
      100 * ids.sum { ms.fetch(_1, 0) } / ms.values.sum
    end
    next [age, nil] if shares.empty? # fewer commits were replayed than this

    [age, { commits: shares.size, ran_everything: shares.count(100.0),
            mean_share_of_test_time: (shares.sum / shares.size).round(1) }]
  end.compact
ensure
  git.("checkout", "-q", "-f", "--detach", start)
  FileUtils.rm_rf(File.join(app, ".pitstop"))
end

File.write(out_path, "#{JSON.pretty_generate(app: File.basename(app), by_map_age: table)}\n", mode: "wb")
table.each { |age, t| puts "map #{age} commits old: ran everything at #{t[:ran_everything]} of #{t[:commits]} commits, #{t[:mean_share_of_test_time]}% of test time on average" }
