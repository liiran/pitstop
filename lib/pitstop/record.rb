# `pitstop record` loads this file into the test process, before anything else:
#
#   RUBYLIB=/path/to/pitstop/lib RUBYOPT=-rpitstop/record bin/rails test
#
# Every Ruby process the tests start inherits those settings, and it may be another Ruby: an old
# system Ruby running a script, or JRuby. The recorder can't run there (it needs Ruby 3.2), and
# must not break that process, so this file is written in Ruby any version can read, and steps
# aside. The recorder itself is in recorder.rb.
if RUBY_ENGINE == "ruby" && (RUBY_VERSION.split(".").map { |part| part.to_i } <=> [3, 2]) >= 0
  require File.expand_path("recorder", File.dirname(__FILE__))
end
