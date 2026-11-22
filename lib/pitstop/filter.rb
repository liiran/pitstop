# Loaded through RUBYOPT by `pitstop run`, before anything else in the test process:
#
#   RUBYOPT="-I/path/to/pitstop/lib -rpitstop/filter" bin/rails test test/models/cart_test.rb
#
# It does two things:
#
# * Minitest: drops every test that wasn't selected from each test class, so only the selected
#   tests run even when a whole test file loads. (RSpec gets its selection on the command line
#   as `spec/x_spec.rb[1:2,1:4]` instead.)
# * Both: writes one line per test that ran, so `pitstop run` can check the tests that ran are
#   exactly the tests it selected.
#
# The selection file (PITSTOP_SELECTION) has one entry per line:
#
#   file test/models/cart_test.rb      run every test in this file (a new or changed test file)
#   test CartTest#test_total           run this test
#
# Like the recorder, this file requires no gem: Bundler hasn't picked gem versions yet.
require_relative "watch"

module Pitstop
  module Filter
    ROOT = File.expand_path(ENV.fetch("PITSTOP_ROOT", Dir.pwd))
    PREFIX = "#{ROOT}/".freeze
    OUT = ENV.fetch("PITSTOP_OUT") { File.join(ROOT, ".pitstop", "ran") }
    # Set while a test runs. A Ruby process the test starts (a CLI test running the tool, or a
    # test suite run by a test) inherits RUBYOPT, so this file loads there too: there it's part of
    # that test, so it neither filters nor logs anything.
    TEST_ENV = "PITSTOP_TEST"

    @tests = {}
    @files = {}
    File.foreach(ENV.fetch("PITSTOP_SELECTION"), chomp: true) do |line|
      kind, value = line.split(" ", 2)
      (kind == "file" ? @files : @tests)[value] = true if value
    end

    class << self
      def keep?(id, file) = @tests.key?(id) || @files.key?(relative(file))

      def relative(path) = path.to_s.delete_prefix(PREFIX)

      # Tab-separated: test id, test file, result.
      def ran(id, file, status)
        log.write("#{id}\t#{relative(file)}\t#{status}\n")
      end

      def log
        return @log if @log && @log_pid == Process.pid

        Dir.mkdir(OUT) unless Dir.exist?(OUT)
        @log_pid = Process.pid
        @log = File.open(File.join(OUT, "#{Process.pid}.tsv"), "a").tap { _1.sync = true }
      end

      def install_minitest
        return if @minitest

        @minitest = true
        ::Minitest::Test.singleton_class.prepend(MinitestFilter)
        ::Minitest::Test.prepend(MinitestLog)
      end

      def install_rspec
        return if @rspec

        @rspec = true
        # The reporter hears about every example that finishes, however it ends: one whose failure
        # is raised out through the around hooks (aggregate_failures), or one failed by an error
        # in its group's before(:context). It exists by before(:suite).
        ::RSpec.configure do |config|
          config.before(:suite) { ::RSpec.configuration.reporter.register_listener(RSpecLog, :example_finished) }
          config.around(:each) do |example|
            ENV[TEST_ENV] = example.id
            example.run
          ensure
            ENV.delete(TEST_ENV)
          end
        end
      end
    end

    module RSpecLog
      STATUS = { passed: "pass", failed: "fail", pending: "skip" }.freeze

      def self.example_finished(notification)
        example = notification.example
        Pitstop::Filter.ran(example.id, Watch.rspec_file(example.metadata), STATUS.fetch(example.execution_result.status, "fail"))
      end
    end

    # Each test class lists only its selected tests. A test that builds and runs a test class
    # inside itself (a test of a test helper) gets that class's tests unfiltered: they're part of
    # the outer test.
    module MinitestFilter
      def runnable_methods
        return super if Thread.current[:pitstop_in_test]

        name = Watch::MODULE_NAME.bind_call(self)
        super.select { |m| Pitstop::Filter.keep?("#{name}##{m}", Watch.minitest_file(self, m)) }
      end
    end

    # Logs each test the framework ran; tests run inside another test are part of that test.
    module MinitestLog
      def run
        return super if Thread.current[:pitstop_in_test]

        id = "#{Watch::MODULE_NAME.bind_call(self.class)}##{name}"
        result = begin
          Thread.current[:pitstop_in_test] = true
          ENV[Pitstop::Filter::TEST_ENV] = id
          super
        ensure
          Thread.current[:pitstop_in_test] = nil
          ENV.delete(Pitstop::Filter::TEST_ENV)
        end
        status = if result.skipped? then "skip"
                 elsif result.passed? then "pass"
                 else "fail"
                 end
        Pitstop::Filter.ran(id, Watch.minitest_file(self.class, name), status)
        result
      end
    end

    module RSpecRun
      def run(*)
        Pitstop::Filter.install_rspec
        super
      end
    end
  end
end

unless ENV[Pitstop::Filter::TEST_ENV]
  Pitstop::Watch.frameworks(minitest: -> { Pitstop::Filter.install_minitest },
                            rspec: ->(runner) { runner.singleton_class.prepend(Pitstop::Filter::RSpecRun) })
end
