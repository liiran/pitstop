#!/bin/sh
# End-to-end check on Fizzy (Rails 8, Minitest, parallel workers), in the Ruby 4 container:
#   docker run --rm -v <pitstop>:/pitstop -v pitstop_bundle4:/usr/local/bundle pitstop-dev4 sh /pitstop/bench/e2e/fizzy.sh
set -e
# Only inside the throwaway dev container: this deletes /work and changes git's global settings.
[ -f /.dockerenv ] || [ -f /run/.containerenv ] || { echo "$0: run this inside the dev container (see compose.yaml), not on your own machine" >&2; exit 1; }
rm -rf /work && mkdir -p /work && cp -r /pitstop/bench/apps/fizzy /work/fizzy && cd /work/fizzy
rm -rf .pitstop
git config --global --add safe.directory '*'
bundle install --quiet >/dev/null 2>&1
export RAILS_ENV=test CI_PROGRESS_BAR=false
bin/rails db:prepare >/dev/null 2>&1
ruby /pitstop/bench/e2e/check.rb /work/fizzy /pitstop/bench/e2e/fizzy.txt
