#!/bin/sh
# End-to-end check on Dead Heat (a gem whose tests start real Rails apps in subprocesses), SQLite,
# in Dead Heat's own Ruby 3.4 container:
#   docker run --rm -v <deadheat>:/deadheat -v <pitstop>:/pitstop -v deadheat_bundle:/usr/local/bundle deadheat-dev sh /pitstop/bench/e2e/deadheat.sh
set -e
rm -rf /work && mkdir -p /work && cp -r /deadheat /work/deadheat && cd /work/deadheat
rm -rf .pitstop
git config --global --add safe.directory '*'
bundle install --quiet >/dev/null 2>&1
export DB=sqlite
ruby /pitstop/bench/e2e/check.rb /work/deadheat /pitstop/bench/e2e/deadheat.txt -- bundle exec rake test:once
