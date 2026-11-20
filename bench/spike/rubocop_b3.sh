#!/bin/sh
# Spike B, part 2: one slice of RuboCop's suite, plain vs per-test vs per-file recording.
set -e
rm -rf /work && mkdir -p /work && cp -r /pitstop/bench/apps/rubocop /work/rubocop && cd /work/rubocop
bundle install --quiet 2>&1 | tail -2
SLICE=spec/rubocop/cop/style
run() { label=$1; shift; start=$(date +%s); "$@" bundle exec rspec $SLICE --format progress 2>&1 | grep -E "examples," | tail -1; echo "$label seconds=$(( $(date +%s) - start ))"; }
run plain env
run per-test env PITSTOP_OUT=/work/out-test RUBYOPT="-I/pitstop/lib -rpitstop/record"
run per-file env PITSTOP_OUT=/work/out-file PITSTOP_GRANULARITY=file RUBYOPT="-I/pitstop/lib -rpitstop/record"
for d in out-test out-file; do
  echo "$d: shards=$(ls /work/$d | wc -l) mb=$(du -sm /work/$d | cut -f1) kinds=$(cat /work/$d/*.jsonl | ruby -rjson -e 'puts STDIN.each_line.map { JSON.parse(_1)["kind"] }.tally')"
done
cp -r /work/out-test /work/out-file /pitstop/bench/spike/
