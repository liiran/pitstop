# Only inside the throwaway dev container: this deletes /work and changes git's global settings.
[ -f /.dockerenv ] || [ -f /run/.containerenv ] || { echo "$0: run this inside the dev container (see compose.yaml), not on your own machine" >&2; exit 1; }
rm -rf /work && mkdir -p /work && cp -r /pitstop/bench/apps/rubocop /work/rubocop && cd /work/rubocop
git config --global --add safe.directory '*'; rm -rf .pitstop
bundle install --quiet >/dev/null 2>&1
start=$(date +%s)
PITSTOP_GRANULARITY=file ruby /pitstop/exe/pitstop record -- bundle exec rspec spec/rubocop/cop/style 2>&1 | grep -E "examples,|Pitstop"
echo "record seconds=$(( $(date +%s) - start ))"
ruby /pitstop/bench/spike/mutants.rb /work/rubocop /pitstop/bench/spike/rubocop_mutants.txt bundle exec rspec spec/rubocop/cop/style
