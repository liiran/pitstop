# `pitstop` with `tests_after_readers: true`, for measuring that setting over real history.
# It can't be measured by writing the setting into .pitstop.yml at each replayed commit: a
# change to .pitstop.yml since the map was made runs everything, as it should.
#
#   ruby bench/e2e/pitstop_tests_after_readers.rb list --json
require_relative "../../lib/pitstop/cli"

Pitstop::CLI.prepend(Module.new do
  private

  def config = super.merge("tests_after_readers" => true)
end)
exit Pitstop::CLI.start(ARGV)
