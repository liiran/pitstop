#!/bin/sh
# End-to-end check on RuboCop (pure Ruby, RSpec, ~36k examples), in the Ruby 4 container:
#   docker run --rm -v <pitstop>:/pitstop -v pitstop_bundle4:/usr/local/bundle pitstop-dev4 sh /pitstop/bench/e2e/rubocop.sh
set -e
rm -rf /work && mkdir -p /work && cp -r /pitstop/bench/apps/rubocop /work/rubocop && cd /work/rubocop
rm -rf .pitstop
git config --global --add safe.directory '*'
bundle install --quiet >/dev/null 2>&1
ruby /pitstop/bench/e2e/check.rb /work/rubocop /pitstop/bench/e2e/rubocop.txt
