# `pitstop run` loads this file into the test process, before anything else:
#
#   RUBYLIB=/path/to/pitstop/lib RUBYOPT=-rpitstop/filter bin/rails test test/models/cart_test.rb
#
# Every Ruby process the tests start inherits those settings, and it may be another Ruby: an old
# system Ruby running a script, or JRuby. The filter can't run there (it needs Ruby 3.2), and must
# not break that process, so this file is written in Ruby any version can read, and steps aside.
# The filter itself is in test_filter.rb.
if RUBY_ENGINE == "ruby" && (RUBY_VERSION.split(".").map { |part| part.to_i } <=> [3, 2]) >= 0
  require File.expand_path("test_filter", File.dirname(__FILE__))
end
