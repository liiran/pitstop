# Only inside the throwaway dev container: this deletes /work and changes git's global settings.
[ -f /.dockerenv ] || [ -f /run/.containerenv ] || { echo "$0: run this inside the dev container (see compose.yaml), not on your own machine" >&2; exit 1; }
rm -rf /work && mkdir -p /work && cp -r /pitstop/bench/apps/fizzy /work/fizzy && cd /work/fizzy
git config --global --add safe.directory '*'
bundle install --quiet >/dev/null 2>&1; export RAILS_ENV=test CI_PROGRESS_BAR=false; bin/rails db:prepare >/dev/null 2>&1
ruby /pitstop/bench/spike/mutants.rb /work/fizzy /pitstop/bench/spike/fizzy_mutants.txt bin/rails test
