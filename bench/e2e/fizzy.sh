#!/bin/sh
# Fizzy (Rails 8, Minitest, parallel workers), in the Ruby 4 container:
#   docker run --rm -v <pitstop>:/pitstop -v pitstop_bundle4:/usr/local/bundle pitstop-dev4 sh /pitstop/bench/e2e/fizzy.sh
#
#   fizzy.sh                  one change at a time (fizzy.txt): what Pitstop picks, and how long it takes
#   fizzy.sh replay <N>       its last N commits, one by one (set OUT to the results file)
#   fizzy.sh mutants <N>      N small planted bugs, one by one (set OUT to the results file)
#
# Fizzy only runs on the Ruby version in its .ruby-version, so replaying commits from before its
# last Ruby upgrade needs an image built with that version (docker/dev.Dockerfile, RUBY_VERSION).
set -e
# Only inside the throwaway dev container: this deletes /work and changes git's global settings.
[ -f /.dockerenv ] || [ -f /run/.containerenv ] || { echo "$0: run this inside the dev container (see compose.yaml), not on your own machine" >&2; exit 1; }
rm -rf /work && mkdir -p /work && cp -r /pitstop/bench/apps/fizzy /work/fizzy && cd /work/fizzy
rm -rf .pitstop
git config --global --add safe.directory '*'
export RAILS_ENV=test
SETUP='(bundle check || bundle install) >/dev/null 2>&1 && bin/rails db:prepare >/dev/null 2>&1'
case "${1:-check}" in
  check)
    sh -c "$SETUP"
    PLAIN_COMMAND="bin/rails test" ruby /pitstop/bench/e2e/check.rb /work/fizzy /pitstop/bench/e2e/fizzy.txt ;;
  replay)
    SETUP="$SETUP" PLAIN_COMMAND="bin/rails test" ruby /pitstop/bench/e2e/replay.rb /work/fizzy "${OUT:?set OUT to the results file}" "${2:-30}" ;;
  mutants)
    sh -c "$SETUP"
    PLAIN_COMMAND="bin/rails test" ruby /pitstop/bench/e2e/mutants.rb /work/fizzy "${OUT:?set OUT to the results file}" "${2:-40}" ;;
esac
