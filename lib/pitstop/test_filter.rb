# Loaded (through pitstop/filter) by `pitstop run`, before anything else in the test process:
#
#   RUBYLIB=/path/to/pitstop/lib RUBYOPT=-rpitstop/filter bin/rails test test/models/cart_test.rb
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
# (names are escaped with Watch.escape, so a newline in a test's name can't add an entry.)
#
# Like the recorder, this file requires no gem: Bundler hasn't picked gem versions yet.
require_relative "watch"

module Pitstop
  module Filter
    ROOT = File.expand_path(ENV.fetch("PITSTOP_ROOT", Dir.pwd))
    PREFIX = "#{ROOT}/".freeze
    OUT = ENV.fetch("PITSTOP_OUT") { File.join(ROOT, ".pitstop", "ran") }
    # Windows paths can differ in case ("c:/app" and "C:/app") and still be the same file.
    WINDOWS = !File::ALT_SEPARATOR.nil?
    # Set while a test runs. A Ruby process the test starts (a CLI test running the tool, or a
    # test suite run by a test) inherits RUBYOPT, so this file loads there too: there it's part of
    # that test, so it neither filters nor logs anything.
    TEST_ENV = "PITSTOP_TEST"

    @tests = {}
    @files = {}

    class << self
      # False when there's no selection to read: a Ruby process that inherited RUBYOPT but not the
      # rest of `pitstop run`'s environment. This file then does nothing there.
      def load_selection
        path = ENV["PITSTOP_SELECTION"]
        return false unless path && File.file?(path)

        File.foreach(path, chomp: true, mode: "rb", encoding: "UTF-8") do |line|
          kind, value = line.split(" ", 2)
          (kind == "file" ? @files : @tests)[Watch.unescape(value)] = true if value
        end
        true
      end

      def keep?(id, file) = @tests.key?(id) || @files.key?(relative(file))

      def relative(path)
        path = path.to_s
        return path[PREFIX.size..] if path.start_with?(PREFIX)
        return path[PREFIX.size..] if WINDOWS && path.size > PREFIX.size && path[0, PREFIX.size].casecmp?(PREFIX)

        path
      end

      # Tab-separated: test id, test file, result.
      def ran(id, file, status)
        log.write("#{Watch.escape(id)}\t#{Watch.escape(relative(file))}\t#{status}\n")
      end

      def log
        return @log if @log && @log_pid == Process.pid

        Dir.mkdir(OUT) unless Dir.exist?(OUT)
        @log_pid = Process.pid
        @log = File.open(File.join(OUT, "#{Process.pid}.tsv"), "ab").tap { _1.sync = true }
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

        super.select { |m| Pitstop::Filter.keep?(Watch.minitest_id(self, m), Watch.minitest_file(self, m)) }
      end
    end

    # Logs each test the framework ran; tests run inside another test are part of that test.
    # It wraps `time_it`, which Minitest::Test#run puts around a whole test, not `run` itself:
    # other gems replace `run` by renaming it (minitest-reporters does), and a renamed method with
    # a wrapper already around it ends up calling itself forever.
    module MinitestLog
      def time_it
        return super if Thread.current[:pitstop_in_test]

        id = Watch.minitest_id(self.class, name)
        result = begin
          Thread.current[:pitstop_in_test] = true
          ENV[Pitstop::Filter::TEST_ENV] = id
          super
        ensure
          Thread.current[:pitstop_in_test] = nil
          ENV.delete(Pitstop::Filter::TEST_ENV)
        end
        status = if skipped? then "skip"
                 elsif passed? then "pass"
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

if !ENV[Pitstop::Filter::TEST_ENV] && Pitstop::Filter.load_selection
  Pitstop::Watch.frameworks(minitest: -> { Pitstop::Filter.install_minitest },
                            rspec: ->(runner) { runner.singleton_class.prepend(Pitstop::Filter::RSpecRun) })
end
