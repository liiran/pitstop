# Loaded (through pitstop/record) by `pitstop record`, before anything else in the test process:
#
#   RUBYLIB=/path/to/pitstop/lib RUBYOPT=-rpitstop/record bin/rails test
#
# It starts Ruby's coverage before any app code loads, then writes one line per finished test
# saying which lines of the project that test ran. It must not require any gem here: the app's
# Bundler hasn't chosen gem versions yet, and loading one early can clash with the Gemfile.
#
# What it writes, one JSON object per line, to .pitstop/runs/<id>/<pid>.jsonl:
#
#   boot         lines that ran while the app and the test files loaded
#   worker_boot  lines a parallel worker ran as it started
#   test         one finished test, with the lines it ran (unless recorded per file)
#   group        per-file recording: the lines all the tests of one test file ran
#   between      RSpec setup shared by a whole spec file (before(:context) and friends)
#   child        lines a subprocess ran for the test that started it
#   summary      how many tests the framework says it ran, to check none went unrecorded
#   error        something that makes the map wrong, such as tests running on threads
require "coverage"
require_relative "watch"

module Pitstop
  module Record
    ROOT = File.expand_path(ENV.fetch("PITSTOP_ROOT", Dir.pwd))
    OUT = ENV.fetch("PITSTOP_OUT") { File.join(ROOT, ".pitstop", "runs", "current") }
    PREFIX = "#{ROOT}/".freeze
    # Lines here belong to gems or tooling, or are test files themselves. A changed test file always
    # runs, so which test ran which line of a test file is never needed, and skipping test files
    # keeps reading coverage cheap on suites with thousands of them.
    SKIP = Regexp.union(Watch::UNFOLLOWED, %r{\A(test|spec)/.*_(test|spec)\.rb\z})
    OWN_FILES = "#{File.expand_path('..', __dir__)}/".freeze

    # "test" reads coverage after every test. "file" reads it once per test file and gives every
    # test in the file the same lines: far cheaper for suites of tiny tests (RuboCop's take ~2 ms
    # each), and selection then runs whole test files. "auto" (the default) starts per test and
    # switches a process to per file once reading coverage costs more than half the tests' own time.
    GRANULARITY = ENV.fetch("PITSTOP_GRANULARITY", "auto")
    AUTO_CHECK_EVERY = 100 # tests

    # Set while a test runs, so a Ruby process the test starts (which inherits RUBYOPT) knows its
    # lines belong to that test.
    TEST_ENV = "PITSTOP_TEST"

    # Windows paths can differ in case ("c:/app" and "C:/app") and still be the same file.
    WINDOWS = !File::ALT_SEPARATOR.nil?

    @per_file = GRANULARITY == "file"
    @other_case = {}
    @child_of = ENV[TEST_ENV]
    @booted = false
    @test = nil
    @nested = 0
    @group = nil
    @shard = nil
    @shard_pid = nil
    @auto = { tests: 0, take_ms: 0.0, test_ms: 0.0 }
    @lock = Mutex.new
    @recorded = {}

    class << self
      # Coverage since the last read, kept only for project files, as {path => [[first, last], ...]}
      # of the lines that ran at least once. `seen`, if given, collects every project file Ruby
      # is tracking, ran or not.
      def take(seen = nil)
        out = {}
        Coverage.result(stop: false, clear: true).each do |path, data|
          next unless in_project?(path)

          seen[path] = true if seen
          lines = data[:lines]
          next if lines.nil? || lines.compact.sum.zero? # cheap, in C: most files ran nothing

          relative = path[PREFIX.size..]
          out[relative] = ranges_of(lines) unless relative.match?(SKIP)
        end
        out
      end

      # Is this file inside the project's folder? Asked about every loaded file after every test,
      # so the usual answer is one prefix comparison.
      def in_project?(path)
        return true if path.start_with?(PREFIX)
        return false unless WINDOWS

        @other_case.fetch(path) do
          @other_case[path] = path.size > PREFIX.size && path[0, PREFIX.size].casecmp?(PREFIX)
        end
      end

      def ranges_of(lines)
        ranges = []
        lines&.each_with_index do |count, i|
          next unless count&.positive?

          line = i + 1
          if ranges.last && ranges.last[1] == line - 1
            ranges.last[1] = line
          else
            ranges << [line, line]
          end
        end
        ranges
      end

      def child? = !@child_of.nil?

      # Called once in the main process when the test files have loaded and tests are about to start
      # (just before parallel workers fork, or before the first test): load the whole app, so code
      # that runs while classes load is counted as boot instead of landing on whichever test
      # happened to load it first.
      def boot!
        return if @booted || child?

        @booted = true
        @watch&.disable # the frameworks (and SimpleCov, if the project uses it) have loaded by now
        eager_load
        seen = {}
        cov = take(seen)
        write(kind: "boot", cov:, unseen: unseen_files(seen))
      end

      # Project files Ruby loaded that coverage isn't tracking: they loaded before coverage started
      # (another RUBYOPT -r, a preloader) or bypassed it (a precompiled-code cache). No test would
      # ever be linked to them.
      def unseen_files(seen)
        $LOADED_FEATURES.filter_map do |path|
          next unless in_project?(path) && path.end_with?(".rb")
          next if seen.key?(path) || path.start_with?(OWN_FILES)

          relative = path[PREFIX.size..]
          relative unless relative.match?(SKIP)
        end
      end

      def eager_load
        return if ENV["PITSTOP_EAGER_LOAD"] == "0"
        return unless defined?(::Rails) && ::Rails.respond_to?(:application) && ::Rails.application

        # One loader at a time: an app can have a loader that's never set up in tests (Rails'
        # application-wide eager_load! then gives up on all of them).
        return ::Rails.application.eager_load! unless ::Rails.respond_to?(:autoloaders)

        ::Rails.autoloaders.each do |loader|
          loader.eager_load
        rescue StandardError => e
          warn "pitstop: skipped loading #{loader.tag rescue 'a loader'} up front (#{e.class}: #{e.message.lines.first&.strip})" unless e.class.name == "Zeitwerk::SetupRequired"
        end
      rescue StandardError => e
        warn "pitstop: couldn't load the whole app first (#{e.class}: #{e.message}); continuing"
      end

      # Minitest.run has begun; with Rails' runner the test files (and the app) load after this,
      # so it's too early to call it boot.
      def tests_loading!
        @tests_loading = true
      end

      def before_fork
        boot! if @tests_loading && !@test && !child?
      end

      # In a freshly forked parallel worker, whatever ran since the last read happened while the
      # worker started up. A fork made by a test is that test's own helper process: its lines
      # belong to the test.
      def after_fork
        @shard = nil
        @group = nil
        if @test
          become_child(@test[:id])
        elsif !child?
          write(kind: "worker_boot", cov: take)
        end
      end

      def become_child(id)
        @child_of = id
        at_exit { Pitstop::Record.child_finished }
      end

      def child_finished
        cov = take
        write(kind: "child", test: @child_of, cov:) unless cov.empty?
      end

      # RSpec is about to run a spec file's top-level group, starting with its before(:context)
      # hooks: lines from those hooks belong to every example in the file, not to whichever
      # example happens to run first.
      def context_started(file)
        return if child?

        if @per_file
          start_group(file)
        else
          shared = take # the previous group's after(:context) hooks
          write(kind: "between", file: @last_file, cov: shared) if @last_file && !shared.empty?
          @context_file = file
        end
      end

      def test_started(id, file)
        return if child?

        boot!
        return threads! if @test && @test[:thread] != Thread.current
        # A test that runs another test inside itself (a test of a test helper, say): the inner
        # test isn't one the framework schedules, so its lines are the outer test's.
        return @nested += 1 if @test

        if @per_file
          start_group(file)
        elsif @context_file
          shared = take # this file's before(:context) hooks
          write(kind: "between", file: @context_file, cov: shared) unless shared.empty?
          @context_file = nil
        end
        @test = { id:, thread: Thread.current }
        ENV[TEST_ENV] = id
      end

      def test_finished(framework:, id:, file:, line:, status:, ms:)
        return if child?
        return @nested -= 1 if @nested.positive?

        @test = nil
        ENV.delete(TEST_ENV)
        @last_file = file
        @recorded[id] = status
        if @per_file
          @group[:tests] << id if @group
          return write(kind: "test", framework:, id:, file:, line:, status:, ms:)
        end

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        cov = take
        take_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(3)
        write(kind: "test", framework:, id:, file:, line:, status:, ms:, take_ms:, cov:)
        auto_switch(take_ms, ms)
      end

      def auto_switch(take_ms, ms)
        return unless GRANULARITY == "auto"

        @auto[:tests] += 1
        @auto[:take_ms] += take_ms
        @auto[:test_ms] += ms.to_f
        return unless (@auto[:tests] % AUTO_CHECK_EVERY).zero? && @auto[:take_ms] > @auto[:test_ms] / 2

        @per_file = true
        write(kind: "switched", after: @auto[:tests], take_ms: @auto[:take_ms].round, test_ms: @auto[:test_ms].round)
      end

      def start_group(file)
        flush_group if @group && @group[:file] != file
        @group ||= { file:, tests: [] }
      end

      # The lines every test of the current test file ran, together.
      def flush_group
        return unless @group

        group = @group
        @group = nil
        write(kind: "group", file: group[:file], tests: group[:tests], cov: take)
      end

      def finished(framework:, ran:, unrecorded: nil)
        flush_group
        write({ kind: "summary", framework:, ran:, unrecorded: }.compact) unless child?
      end

      # A test's final result, once its framework has decided it. A test the hooks never saw run
      # is recorded with no lines (as failed or skipped, it always runs); one whose result
      # changed after the hooks finished gets its status corrected.
      def result(id:, status:)
        return if child?

        if !@recorded.key?(id)
          @recorded[id] = status
          write(kind: "test", id:, status:, ms: 0, **yield)
        elsif @recorded[id] != status
          @recorded[id] = status
          write(kind: "status", id:, status:)
        end
      end

      # Up to 20 of these test ids that this process never recorded, to name in the warning.
      def unrecorded(ids) = ids.reject { @recorded.key?(_1) }.first(20)

      # Tests running at the same time on several threads share one coverage counter, so lines
      # can't be told apart. Say so once and stop recording.
      def threads!
        message = "tests ran on several threads at once, so their lines can't be told apart. " \
                  "Record with one thread (for Rails: parallelize(with: :processes), or PARALLEL_WORKERS=1)"
        warn "pitstop: #{message}"
        write(kind: "error", message:)
        @child_of = "(stopped)"
      end

      def write(record)
        @lock.synchronize { shard.puts(JSON.generate(record.merge(pid: Process.pid))) }
      end

      def shard
        return @shard if @shard && @shard_pid == Process.pid

        require "json" # safe now: by the time tests run, Bundler has picked gem versions
        require "fileutils"
        FileUtils.mkdir_p(OUT)
        @shard_pid = Process.pid
        @shard = File.open(File.join(OUT, "#{Process.pid}.jsonl"), "a").tap { _1.sync = true }
      end

      # A file's path inside the project, or nil for a file outside it (a test class that
      # comes from a gem): paths outside the project never go into the map.
      def relative(path)
        path = path.to_s
        path[PREFIX.size..] if in_project?(path)
      end

      def install_minitest
        return if @minitest

        @minitest = true
        ::Minitest.singleton_class.prepend(MinitestRun)
        ::Minitest::Test.prepend(MinitestTest)
      end

      def count_minitest_results
        return if @minitest_reporter

        @minitest_reporter = true
        @minitest_ran = 0
        ::Minitest::CompositeReporter.prepend(MinitestReporter)
      end

      def minitest_result = @minitest_ran += 1

      def minitest_finished = finished(framework: "minitest", ran: @minitest_ran.to_i)

      # Called as RSpec's runner starts, before spec files (and their spec_helper) load, so these
      # hooks wrap every other one.
      def install_rspec
        return if @rspec

        @rspec = true
        ::RSpec.configure do |config|
          config.before(:suite) do
            Pitstop::Record.boot!
            ::RSpec.configuration.reporter.register_listener(RSpecResults, :example_finished)
          end
          config.before(:context) do
            Pitstop::Record.context_started(Pitstop::Record.relative(Pitstop::Watch.rspec_file(self.class.metadata)))
          end
          config.after(:suite) do
            ran = ::RSpec.configuration.reporter.examples.map(&:id)
            Pitstop::Record.finished(framework: "rspec", ran: ran.size, unrecorded: Pitstop::Record.unrecorded(ran))
          end
          config.around(:each) do |example|
            file = Pitstop::Record.relative(Pitstop::Watch.rspec_file(example.metadata))
            started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            Pitstop::Record.test_started(example.id, file)
            raised = nil
            begin
              example.run
            rescue Exception => e # rubocop:disable Lint/RescueException
              # aggregate_failures (and some around hooks) raise the failure out through every
              # around hook; it's still a finished, failed example.
              raised = e
              raise
            ensure
              ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(3)
              status = if raised || example.exception then "fail"
                       elsif example.pending? || example.skipped? then "skip"
                       else "pass"
                       end
              Pitstop::Record.test_finished(framework: "rspec", id: example.id, file:,
                                            line: example.metadata[:line_number], status:, ms:)
            end
          end
        end
      end

      def watch_for_frameworks
        @watch = Watch.frameworks(minitest: -> { install_minitest },
                                  rspec: ->(runner) { runner.singleton_class.prepend(RSpecRun) },
                                  simplecov: ->(simplecov) { simplecov.singleton_class.prepend(SimpleCovOff) })
      end

      def simplecov_is_off
        return if @said_simplecov_is_off || child?

        @said_simplecov_is_off = true
        warn "pitstop: SimpleCov is off while recording (Ruby has one coverage counter, and the recorder is using it)"
      end
    end

    # Minitest.run happens once, in the main process, before parallel workers start; every result
    # (including those parallel workers send back) is recorded by its reporter there.
    module MinitestRun
      def run(*)
        Pitstop::Record.tests_loading!
        Pitstop::Record.count_minitest_results
        super
      ensure
        Pitstop::Record.minitest_finished
      end
    end

    module MinitestReporter
      def record(result)
        Pitstop::Record.minitest_result
        super
      end
    end

    # Wraps `time_it`, which Minitest::Test#run puts around a whole test (setup, the test,
    # teardown), not `run` itself. Other gems replace `run` by renaming it (minitest-reporters
    # does), and a renamed method with a wrapper already around it ends up calling itself forever.
    module MinitestTest
      def time_it
        klass = self.class
        id = Watch.minitest_id(klass, name)
        file = Pitstop::Record.relative(Watch.minitest_file(klass, name))
        Pitstop::Record.test_started(id, file)
        result = super
        status = if skipped? then "skip"
                 elsif passed? then "pass"
                 else "fail"
                 end
        Pitstop::Record.test_finished(framework: "minitest", id:, file:, line: Watch.minitest_line(klass, name),
                                      status:, ms: (time.to_f * 1000).round(3))
        result
      end
    end

    module RSpecRun
      def run(*)
        Pitstop::Record.install_rspec
        super
      end
    end

    # RSpec decides an example's result after every around hook has returned (aggregate_failures
    # wraps them all), and some examples never reach the around hooks: those skipped up front,
    # and those failed by an error in their group's before(:context). The reporter hears the final
    # result of every one.
    module RSpecResults
      STATUS = { passed: "pass", failed: "fail", pending: "skip" }.freeze

      def self.example_finished(notification)
        example = notification.example
        status = STATUS.fetch(example.execution_result.status, "fail")
        Pitstop::Record.result(id: example.id, status:) do
          { framework: "rspec", file: Pitstop::Record.relative(Watch.rspec_file(example.metadata)),
            line: example.metadata[:line_number] }
        end
      end
    end

    # Ruby has one coverage counter. While recording it's Pitstop's, read and cleared after every
    # test, so SimpleCov would report almost nothing covered: failing the run on a minimum-coverage
    # setting, and overwriting the project's last real report. Its `start` does nothing instead.
    module SimpleCovOff
      def start(*)
        Pitstop::Record.simplecov_is_off
        nil
      end
    end

    module ForkWatch
      def _fork
        Pitstop::Record.before_fork
        pid = super
        Pitstop::Record.after_fork if pid.zero?
        pid
      end
    end
  end
end

Coverage.setup(lines: true, eval: true)
Coverage.resume
Process.singleton_class.prepend(Pitstop::Record::ForkWatch) if Process.respond_to?(:_fork)
if Pitstop::Record.child?
  # Started from inside a test: everything this process runs belongs to that test.
  at_exit { Pitstop::Record.child_finished }
  Pitstop::Watch.frameworks(simplecov: ->(simplecov) { simplecov.singleton_class.prepend(Pitstop::Record::SimpleCovOff) })
else
  # Forked workers that end without returning to Minitest.run still get their last file written.
  at_exit { Pitstop::Record.flush_group }
  Pitstop::Record.watch_for_frameworks
end
