# Loaded through RUBYOPT by `pitstop record`, before anything else in the test process:
#
#   RUBYOPT="-I/path/to/pitstop/lib -rpitstop/record" bin/rails test
#
# It starts Ruby's coverage before any app code loads, then writes one line per finished test
# saying which lines of the project that test ran. It must not require any gem here: the app's
# Bundler hasn't chosen gem versions yet, and loading one early can clash with the Gemfile.
require "coverage"

module Pitstop
  module Record
    ROOT = File.expand_path(ENV.fetch("PITSTOP_ROOT", Dir.pwd))
    OUT = ENV.fetch("PITSTOP_OUT") { File.join(ROOT, ".pitstop", "runs", "current") }
    PREFIX = "#{ROOT}/".freeze
    # Lines here belong to gems or tooling, or are test files themselves. A changed test file always
    # runs, so which test ran which line of a test file is never needed, and skipping test files
    # keeps reading coverage cheap on suites with thousands of them.
    SKIP = %r{\A(vendor|tmp|node_modules|\.bundle|\.pitstop)/|\A(test|spec)/.*_(test|spec)\.rb\z}

    # "test" reads coverage after every test. "file" reads it once per test file and gives every
    # test in the file the same lines: far cheaper for suites of tiny tests (RuboCop's take ~2 ms
    # each), and selection then runs whole test files.
    GRANULARITY = ENV.fetch("PITSTOP_GRANULARITY", "test")

    @parent_pid = Process.pid
    @group = nil
    @booted = false
    @shard = nil
    @shard_pid = nil

    class << self
      # Coverage since the last read, kept only for project files, as {path => [[first, last], ...]}
      # of the lines that ran at least once.
      def take
        out = {}
        Coverage.result(stop: false, clear: true).each do |path, data|
          next unless path.start_with?(PREFIX)

          lines = data[:lines]
          next if lines.nil? || lines.compact.sum.zero? # cheap, in C: most files ran nothing

          relative = path.delete_prefix(PREFIX)
          out[relative] = ranges_of(lines) unless relative.match?(SKIP)
        end
        out
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

      # Called once in the main process just before the first test: load the whole app, so code that
      # runs while classes load is counted as boot instead of landing on whichever test loaded it.
      def boot!
        return if @booted

        @booted = true
        eager_load
        write(kind: "boot", cov: take)
      end

      def eager_load
        return if ENV["PITSTOP_EAGER_LOAD"] == "0"
        return unless defined?(::Rails) && ::Rails.respond_to?(:application) && ::Rails.application

        ::Rails.application.eager_load!
      rescue StandardError => e
        warn "pitstop: couldn't load the whole app first (#{e.class}: #{e.message}); continuing"
      end

      # In a freshly forked worker: whatever ran since the last read happened while the worker
      # started up, not in a test.
      #
      # A fork made from inside a test (the test's own subprocess) records nothing: its lines belong
      # to that test, and counting them as start-up would make them look like boot code.
      def after_fork
        @shard = nil
        @group = nil
        if @in_test
          @silent = true
        else
          write(kind: "worker_boot", cov: take)
        end
      end

      # Per test file, the previous file's lines are read here, before this test runs: reading them
      # after would hand this test's lines to the previous file (tests run in random order, so
      # that file can be anything).
      def test_started(file)
        @in_test = true
        return unless GRANULARITY == "file"

        flush_group if @group && @group[:file] != file
        @group ||= { file:, tests: [] }
      end

      def test_finished(framework:, id:, file:, line:, status:, ms:)
        @in_test = false
        if GRANULARITY == "file"
          @group[:tests] << id if @group
          return write(kind: "test", framework:, id:, file:, line:, status:, ms:)
        end

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        cov = take
        take_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(2)
        write(kind: "test", framework:, id:, file:, line:, status:, ms:, take_ms:, cov:)
      end

      # The lines every test of the current test file ran, together.
      def flush_group
        return unless @group

        group = @group
        @group = nil
        write(kind: "group", file: group[:file], tests: group[:tests], cov: take)
      end

      def write(record)
        return if @silent

        shard.puts(JSON.generate(record.merge(pid: Process.pid)))
      end

      def shard
        return @shard if @shard && @shard_pid == Process.pid

        require "json" # safe now: by the time tests run, Bundler has picked gem versions
        require "fileutils"
        FileUtils.mkdir_p(OUT)
        @shard_pid = Process.pid
        @shard = File.open(File.join(OUT, "#{Process.pid}.jsonl"), "a").tap { _1.sync = true }
      end

      def relative(path)
        path.to_s.delete_prefix("#{ROOT}/")
      end

      def install_hooks
        install_minitest if !@minitest && defined?(::Minitest::Test) && defined?(::Minitest.run)
        install_rspec if !@rspec && defined?(::RSpec::Core::Configuration) && ::RSpec.respond_to?(:configure)
      end

      def install_minitest
        @minitest = true
        ::Minitest.singleton_class.prepend(MinitestRun)
        ::Minitest::Test.prepend(MinitestTest)
      end

      def install_rspec
        @rspec = true
        ::RSpec.configure do |config|
          config.before(:suite) { Pitstop::Record.boot! }
          config.after(:suite) { Pitstop::Record.flush_group }
          config.around(:each) do |example|
            # The spec file that runs this example; for a shared example that's the file including it.
            file = Pitstop::Record.relative(File.expand_path(example.metadata[:rerun_file_path] || example.metadata[:file_path]))
            started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            Pitstop::Record.test_started(file)
            example.run
            ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)
            status = if example.exception then "fail"
                     elsif example.pending? || example.skipped? then "skip"
                     else "pass"
                     end
            Pitstop::Record.test_finished(framework: "rspec", id: example.id, file:,
                                          line: example.metadata[:line_number], status:, ms:)
          end
        end
      end
    end

    # Minitest.run happens once, in the main process, before parallel workers start.
    module MinitestRun
      def run(*)
        Pitstop::Record.boot!
        super
      ensure
        Pitstop::Record.flush_group
      end
    end

    module MinitestTest
      def run
        file, line = Pitstop::Record.minitest_location(self)
        Pitstop::Record.test_started(file)
        result = super
        status = if result.skipped? then "skip"
                 elsif result.passed? then "pass"
                 else "fail"
                 end
        Pitstop::Record.test_finished(framework: "minitest", id: "#{self.class.name}##{name}", file:, line:,
                                      status:, ms: (result.time * 1000).round(1))
        result
      end
    end

    # The file that defines the test class (so tests mixed in from a module still map to the test
    # file that runs them), and the test method's line.
    def self.minitest_location(test)
      method_file, line = test.method(test.name).source_location rescue [nil, nil]
      class_file = (Object.const_source_location(test.class.name)&.first if test.class.name) rescue nil
      [relative(class_file || method_file), line]
    end

    # Watches requires, so the hooks go in as soon as Minitest or RSpec has loaded.
    module RequireWatch
      def require(path)
        loaded = super
        Pitstop::Record.install_hooks if loaded
        loaded
      end
    end

    module ForkWatch
      def _fork
        pid = super
        Pitstop::Record.after_fork if pid.zero?
        pid
      end
    end
  end
end

# Forked workers that end without returning to Minitest.run still get their last file written.
at_exit { Pitstop::Record.flush_group } if Pitstop::Record::GRANULARITY == "file"

Coverage.setup(lines: true, eval: true)
Coverage.resume
Kernel.prepend(Pitstop::Record::RequireWatch)
Process.singleton_class.prepend(Pitstop::Record::ForkWatch) if Process.respond_to?(:_fork)
