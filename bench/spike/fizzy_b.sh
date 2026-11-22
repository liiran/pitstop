#!/bin/sh
# Spike B on Fizzy: plain run vs recorded run (parallel workers on), on the container's filesystem.
set -e
# Only inside the throwaway dev container: this deletes /work and changes git's global settings.
[ -f /.dockerenv ] || [ -f /run/.containerenv ] || { echo "$0: run this inside the dev container (see compose.yaml), not on your own machine" >&2; exit 1; }
rm -rf /work && mkdir -p /work && cp -r /pitstop/bench/apps/fizzy /work/fizzy && cd /work/fizzy
bundle install --quiet 2>&1 | tail -3
export RAILS_ENV=test CI_PROGRESS_BAR=false
bin/rails db:prepare >/dev/null 2>&1 || bin/rails db:prepare 2>&1 | tail -5
echo "workers: $(nproc)"
run() { label=$1; shift; start=$(date +%s); "$@" bin/rails test 2>&1 | grep -E "runs,|pitstop" | tail -2; echo "$label seconds=$(( $(date +%s) - start ))"; }
run plain env
run per-test env PITSTOP_OUT=/work/out RUBYOPT="-I/pitstop/lib -rpitstop/record"
run per-file env PITSTOP_OUT=/work/out-file PITSTOP_GRANULARITY=file RUBYOPT="-I/pitstop/lib -rpitstop/record"
ruby -rjson -e '
  recs = Dir["/work/out/*.jsonl"].flat_map { File.readlines(_1).map { |l| JSON.parse(l) } }
  tests = recs.select { _1["kind"] == "test" }
  takes = tests.map { _1["take_ms"] }.sort
  files = tests.map { _1["cov"].size }.sort
  puts "shards=#{Dir["/work/out/*.jsonl"].size} kinds=#{recs.map { _1["kind"] }.tally}"
  puts "tests=#{tests.size} take_ms median=#{takes[takes.size/2]} p90=#{takes[takes.size*9/10]} total_s=#{(takes.sum/1000).round(1)}"
  puts "files per test median=#{files[files.size/2]} p90=#{files[files.size*9/10]} shard_mb=#{(Dir["/work/out/*.jsonl"].sum { File.size(_1) }/1e6).round(1)}"
  puts "statuses=#{tests.map { _1["status"] }.tally}"
  erb = tests.count { |t| t["cov"].keys.any? { _1.end_with?(".erb") } }
  puts "tests that rendered an .erb template: #{erb}"
'
rm -rf /pitstop/bench/spike/fizzy_out /pitstop/bench/spike/fizzy_out_file; cp -r /work/out /pitstop/bench/spike/fizzy_out; cp -r /work/out-file /pitstop/bench/spike/fizzy_out_file
