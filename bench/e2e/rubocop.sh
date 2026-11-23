#!/bin/sh
# RuboCop (pure Ruby, RSpec, ~36k examples), in the Ruby 4 container:
#   docker run --rm -v <pitstop>:/pitstop -v pitstop_bundle4:/usr/local/bundle pitstop-dev4 sh /pitstop/bench/e2e/rubocop.sh
#
#   rubocop.sh                one change at a time (rubocop.txt): what Pitstop picks, and how long it takes
#   rubocop.sh replay <N>     its last N commits, one by one (set OUT to the results file)
#   rubocop.sh mutants <N>    N small planted bugs, one by one (set OUT to the results file)
#
# Both sides run `bundle exec rspec` in one process. (RuboCop's own CI spreads its suite over the
# machine's cores with `rake spec`; Pitstop hasn't been tried with that.)
set -e
# Only inside the throwaway dev container: this deletes /work and changes git's global settings.
[ -f /.dockerenv ] || [ -f /run/.containerenv ] || { echo "$0: run this inside the dev container (see compose.yaml), not on your own machine" >&2; exit 1; }
rm -rf /work && mkdir -p /work && cp -r /pitstop/bench/apps/rubocop /work/rubocop && cd /work/rubocop
rm -rf .pitstop
git config --global --add safe.directory '*'
SETUP='(bundle check || bundle install) >/dev/null 2>&1'
case "${1:-check}" in
  check)
    sh -c "$SETUP"
    PLAIN_COMMAND="bundle exec rspec" ruby /pitstop/bench/e2e/check.rb /work/rubocop /pitstop/bench/e2e/rubocop.txt ;;
  replay)
    SETUP="$SETUP" PLAIN_COMMAND="bundle exec rspec" ruby /pitstop/bench/e2e/replay.rb /work/rubocop "${OUT:?set OUT to the results file}" "${2:-10}" ;;
  mutants)
    sh -c "$SETUP"
    PLAIN_COMMAND="bundle exec rspec" ruby /pitstop/bench/e2e/mutants.rb /work/rubocop "${OUT:?set OUT to the results file}" "${2:-20}" ;;
esac
