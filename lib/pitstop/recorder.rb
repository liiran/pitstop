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
#
# Besides `cov` (the lines), a record can carry `reads`, the project files opened since the last
# record, and `lists`, the folders listed, as the patterns asked for ("changelog/*.md"). A test
# that reads a file or lists a folder depends on it without running a line of it.
#
# And, as each process ends, .pitstop/runs/<id>/names-<n>.json: the name of every method any class
# or module has, and the project's classes and modules (see Record.names!).
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
    # Ruby's own "list this class's methods", kept before LISTERS below wraps them.
    LISTING = %i[instance_methods public_instance_methods protected_instance_methods private_instance_methods]
              .to_h { [_1, Module.instance_method(_1)] }.freeze
    LISTING_OBJECT = %i[methods public_methods private_methods singleton_methods].to_h { [_1, Kernel.instance_method(_1)] }.freeze
    ANCESTORS = Module.instance_method(:ancestors)
    SINGLETON_CLASS = Kernel.instance_method(:singleton_class)
    CLASS_OF = Kernel.instance_method(:class)

    @auto = { tests: 0, take_ms: 0.0, test_ms: 0.0 }
    @lock = Mutex.new
    @recorded = {}
    @listed = { instance: {}.compare_by_identity, private_instance: {}.compare_by_identity,
                class_side: {}.compare_by_identity, private_class_side: {}.compare_by_identity }
    @opened = { reads: {}, lists: {} }
    @while_loading = {}
    # Files that are written as the suite runs, not read as part of the project.
    NOT_PROJECT_DATA = Regexp.union(Watch::UNFOLLOWED, %r{\A(log|storage|coverage|\.git)/})
    TEST_FILE = %r{\A(test|spec)/.*_(test|spec)\.rb\z}
    GLOB_SIGNS = /[\\*?\[\]{}]/
    UNTIDY = %r{/\.{0,2}(/|\z)} # "//", "/./", "/../", or a slash at the end
    # Names Ruby gives to code that has no file ("(eval at /gems/x.rb:3)", "<STDOUT>"): asked about
    # as if they were files in the current folder, and they can carry a path from elsewhere.
    NOT_A_FILE = %r{\A\((eval|erb|irb|pry|haml|slim)\b|\A<[^/]*>\z|[( ]/|[( ][A-Za-z]:[/\\]}
    # The file name the methods put in front of built-in ones are filed under, so their frames
    # can be told apart (see Record.unframe).
    CLEAN_TRACES = RUBY_VERSION >= "3.4"
    HOOK = (CLEAN_TRACES ? "#{__FILE__} (in front of a built-in method)" : __FILE__).freeze

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
        tracked = {}
        cov = take(tracked)
        loading = @while_loading.transform_values { |opened| opened.transform_values(&:keys).reject { |_, list| list.empty? } }
        write({ kind: "boot", cov:, unseen: unseen_files(tracked), loading: (loading unless loading.empty?), **seen }.compact)
      end

      # --- files read and folders looked into ----------------------------------------------------
      #
      # The four methods below are what the methods put in front of File, IO and Dir call (see
      # `watch_files`). Noting must never change what the app's own call does, so whatever goes
      # wrong in one of them is swallowed. That includes being called from another Ractor, where
      # the recorder's own state can't be reached.

      # Before the tests start, it matters which code asked: see #opened.
      def loading? = !@booted && !@test && !child?

      # The code that asked, while test files are still loading: [3] is the caller of the built-in
      # method (this is called by a note, which is called by the method put in front).
      def asker = loading? ? caller_locations(3, 25) : nil

      # Some code opened this file, or asked something only its contents can answer (its size, when
      # it last changed).
      def file_read(path)
        from = asker
        relative = project_data(path) and opened(:reads, relative, from)
      rescue StandardError
        nil
      end

      # Some code asked which files exist: `Dir["changelog/*.md"]`. What it depends on is the
      # pattern, since a file added later that matches it changes the answer.
      def files_listed(patterns, base = nil)
        patterns_asked(patterns, base, asker)
      rescue StandardError
        nil
      end

      # Some code asked what is in a folder: `Dir.children("docs")`.
      def folder_listed(folder)
        from = asker
        folder = folder.to_path if !folder.is_a?(String) && folder.respond_to?(:to_path)
        patterns_asked(File.join(folder, "*"), nil, from) if folder.is_a?(String)
      rescue StandardError
        nil
      end

      # Some code asked whether this one file or folder exists: a pattern that only it matches.
      def existence_asked(path)
        from = asker
        relative = project_data(path) and opened(:lists, relative.gsub(GLOB_SIGNS) { "\\#{_1}" }, from)
      rescue StandardError
        nil
      end

      def patterns_asked(patterns, base, called_from)
        Array(patterns).each do |pattern|
          pattern = pattern.to_path if !pattern.is_a?(String) && pattern.respond_to?(:to_path)
          next unless pattern.is_a?(String)

          # "{a,b}/*.yml" is asked as "a/*.yml" and "b/*.yml": a choice may be a whole path, in or
          # out of the project (Rails asks for "{/app/test/fixtures/}/users{.yml,/**/*.yml}").
          choices = braces(pattern)
          # Too many to spell out: any file added or removed might answer it.
          next opened(:lists, "**/*", called_from) if choices.nil?

          choices.each { |choice| relative = project_data(choice, base) and opened(:lists, relative, called_from) }
        end
      end

      # An error that passed through a method put in front of a built-in one shouldn't show that
      # method in its trace: a test may look at where an error came from. Ruby can drop frames
      # from a trace and keep the rest as it was from 3.4 on; before that the frame stays.
      def unframe(error)
        return unless CLEAN_TRACES

        locations = error.backtrace_locations
        error.set_backtrace(locations.reject { _1.path == HOOK }) if locations&.any? { _1.path == HOOK }
      rescue StandardError
        nil
      end

      # A pattern with its {a,b} choices spelled out; nil when that makes more than `limit`.
      def braces(pattern, limit = 64)
        depth = 0
        cuts = []
        index = 0
        while index < pattern.size
          case pattern[index]
          when "\\" then index += 1
          when "{"
            cuts << index if depth.zero?
            depth += 1
          when ","
            cuts << index if depth == 1
          when "}"
            depth -= 1 if depth.positive?
            if depth.zero? && !cuts.empty?
              head = pattern[0...cuts.first]
              tail = pattern[(index + 1)..]
              all = []
              [*cuts, index].each_cons(2) do |from, to|
                found = braces(head + pattern[(from + 1)...to] + tail, limit) or return nil
                return nil if all.concat(found).size > limit
              end
              return all
            end
          end
          index += 1
        end
        [pattern]
      end

      # The path inside the project, for a file (or pattern) that is part of it; nil for anything
      # else: files outside it, logs and databases the suite itself writes, things that aren't paths.
      def project_data(path, base = nil)
        path = path.to_path if !path.is_a?(String) && path.respond_to?(:to_path)
        return unless path.is_a?(String) && !path.empty? && !path.start_with?("|") && !path.include?("\0")

        # A plain path under the project is used as it is; anything else ("a//b", "a/../b", a path
        # from the current folder) is first made into one.
        full = !base && path.start_with?(PREFIX) && !path.match?(UNTIDY) ? path : File.expand_path(path, *base)
        # Not #in_project?, which remembers every path it was asked about: this is asked about
        # every file the tests touch.
        return unless full.start_with?(PREFIX) || (WINDOWS && full.size > PREFIX.size && full[0, PREFIX.size].casecmp?(PREFIX))

        relative = full[PREFIX.size..]
        relative unless relative.empty? || relative.match?(NOT_PROJECT_DATA) || relative.match?(NOT_A_FILE)
      end

      # Where a read or a listing belongs. In a test (or between two): to the next record written,
      # which is that test's or its file's. Before the tests, it depends on the nearest project
      # code that asked: a test file's own top-level code (a spec that makes one example per file
      # in a folder) means that test file; anything else is part of starting the app, which every
      # test depends on.
      def opened(kind, path, called_from)
        target = @opened
        if called_from
          asker = nil
          called_from.each do |location|
            file = relative(location.absolute_path || location.path || "")
            break asker = file if file && !file.match?(Watch::UNFOLLOWED)
          end
          target = (@while_loading[asker] ||= { reads: {}, lists: {} }) if asker&.match?(TEST_FILE)
        end
        target[kind][path] = true
      end

      # What was opened since the last record, to go into the next one.
      def seen
        return {} if @opened[:reads].empty? && @opened[:lists].empty?

        was = @opened
        @opened = { reads: {}, lists: {} }
        { reads: was[:reads].keys, lists: was[:lists].keys }.reject { |_, list| list.empty? }
      end

      # Some code asked for the list of a class's methods (`side` says which ones). Whatever it
      # does with the list, it can find a method nobody calls by name: RuboCop runs a cop's
      # `on_send`, `on_def`... because they show up in `public_instance_methods`.
      def listed(mod, side)
        @listed[side][mod] = true
      rescue StandardError
        nil # from another Ractor, where this can't be reached
      end

      # `Cart.methods` lists the class's own methods, `cart.methods` those of a Cart.
      def listed_on(object, private_ones)
        if Module === object then listed(object, private_ones ? :private_class_side : :class_side)
        else listed(CLASS_OF.bind_call(object), private_ones ? :private_instance : :instance)
        end
      rescue StandardError
        nil
      end

      # Written by every process as it ends, for `pitstop run` to judge a method that gets added
      # later. Under a name no class or module had, in a class whose methods nothing lists, no code
      # could have been calling it; under a name that existed, it may be replacing the method some
      # test relied on.
      #
      #   methods  the name of every method any class or module has (the app's, its gems', Ruby's)
      #   modules  the project's own classes and modules, each with whose-methods-were-listed
      #            marks: i its public methods, I its private ones, c and C the same for the
      #            methods of the class itself (`def self.x`)
      def names!
        return if @names_written == Process.pid

        @names_written = Process.pid
        methods = {}
        modules = {}
        ObjectSpace.each_object(Module) do |mod|
          LISTING[:instance_methods].bind_call(mod, false).each { methods[_1] = true }
          LISTING[:private_instance_methods].bind_call(mod, false).each { methods[_1] = true }
          LISTING_OBJECT[:singleton_methods].bind_call(mod, false).each { methods[_1] = true }
          name = Watch::MODULE_NAME.bind_call(mod)
          modules[name] = +"" if name && project_module?(name)
        end
        mark = ->(mod, letter) { (marks = modules[Watch::MODULE_NAME.bind_call(mod)]) && !marks.include?(letter) && marks << letter }
        { instance: "i", private_instance: "I" }.each do |side, letter|
          # A class's list includes what it inherits and what is mixed into it.
          @listed[side].each_key { |mod| ANCESTORS.bind_call(mod).each { mark.(_1, letter) } }
        end
        { class_side: "c", private_class_side: "C" }.each do |side, letter|
          @listed[side].each_key do |mod|
            ANCESTORS.bind_call(SINGLETON_CLASS.bind_call(mod)).each do |ancestor|
              # The class's own methods live in singleton classes (its and its superclasses'); a
              # module it was extended with contributes its instance methods.
              if ancestor.singleton_class? then mark.(ancestor.attached_object, letter) if Module === ancestor.attached_object
              else mark.(ancestor, letter == "c" ? "i" : "I")
              end
            end
          end
        end

        require "json"
        require "zlib"
        require "fileutils"
        body = JSON.generate(methods: methods.keys.map { _1.to_s.scrub("?") }.sort, modules:)
        FileUtils.mkdir_p(OUT)
        path = File.join(OUT, "names-#{methods.size}-#{Zlib.crc32(body)}.json")
        return if File.exist?(path) # another process with the same code loaded got here first

        File.write("#{path}.#{Process.pid}.tmp", body)
        File.rename("#{path}.#{Process.pid}.tmp", path)
      rescue StandardError => e
        warn "pitstop: couldn't note the method names (#{e.class}: #{e.message.lines.first&.strip})"
      end

      # Is this class or module defined in one of the project's own files?
      def project_module?(name)
        return false unless name.match?(/\A[A-Z]\w*(::[A-Z]\w*)*\z/)

        file = Object.const_source_location(name)&.first
        !file.nil? && in_project?(file) && !file[PREFIX.size..].match?(Watch::UNFOLLOWED)
      rescue NameError, ArgumentError
        false
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
          write(kind: "worker_boot", cov: take, **seen)
        end
      end

      def become_child(id)
        @child_of = id
        at_exit { Pitstop::Record.child_finished }
      end

      def child_finished
        cov = take
        opened = seen
        write(kind: "child", test: @child_of, cov:, **opened) unless cov.empty? && opened.empty?
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
          opened = @last_file ? seen : {}
          write(kind: "between", file: @last_file, cov: shared, **opened) if @last_file && !(shared.empty? && opened.empty?)
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
          opened = seen
          write(kind: "between", file: @context_file, cov: shared, **opened) unless shared.empty? && opened.empty?
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
        write(kind: "test", framework:, id:, file:, line:, status:, ms:, take_ms:, cov:, **seen)
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
        write(kind: "group", file: group[:file], tests: group[:tests], cov: take, **seen)
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

    # Puts a note in front of a built-in method, in place: the method keeps its name and its place,
    # and the original stays reachable under a private name beside it. Not through a module put
    # in front of the class, which would show up in `ancestors`, something a project's own tests
    # may look at. And written with `def`, not a block: a method made from a block can't be
    # called from another Ractor, and tests that use Ractors read files too. (There the note is
    # skipped: what the recorder knows lives in the main Ractor.)
    #
    #   owner   the class or module whose instances have the method (a singleton class for
    #           `File.read` and the like)
    #   note    Ruby code for the note, which can use `args`, `options` and `self`
    def self.put_in_front(owner, name, note, keywords: true)
      original = "__pitstop_#{name.to_s.sub('?', '_p').sub('[]', 'index')}"
      hidden = owner.private_method_defined?(name)
      owner.send(:alias_method, original, name)
      owner.send(:private, original)
      params = keywords ? "*args, **options, &block" : "*args, &block"
      owner.class_eval(<<~RUBY, HOOK, 1)
        def #{name}(#{params})
          #{note}
          #{original}(#{params})
        rescue ::Exception => error
          ::Pitstop::Record.unframe(error)
          ::Kernel.raise
        end
      RUBY
      owner.send(:private, name) if hidden
    end

    # Notes who asks for a list of methods, then answers as Ruby would.
    def self.watch_listing
      quiet, $VERBOSE = $VERBOSE, nil # replacing a built-in method is meant here
      { instance_methods: :instance, public_instance_methods: :instance, protected_instance_methods: :instance,
        private_instance_methods: :private_instance }.each do |name, side|
        put_in_front(Module, name, "::Pitstop::Record.listed(self, :#{side})", keywords: false)
      end
      { methods: false, public_methods: false, singleton_methods: false, private_methods: true }.each do |name, private_ones|
        put_in_front(Kernel, name, "::Pitstop::Record.listed_on(self, #{private_ones})", keywords: false)
      end
    ensure
      $VERBOSE = quiet
    end

    # Notes which files get read and which folders get looked into, then does what Ruby would.
    # What this can't see is in the README: a file opened by a program the test starts that
    # isn't Ruby, or by a gem's C code.
    def self.watch_files
      quiet, $VERBOSE = $VERBOSE, nil
      read = "::Pitstop::Record.file_read(args.first)"
      asked = "::Pitstop::Record.existence_asked(args.first)"
      folder = "::Pitstop::Record.folder_listed(args.first)"

      # File.open, File.new, Kernel#open and Pathname#open all make a File.
      put_in_front(File, :initialize, read)
      # These read a file without making a File, or answer from its contents. `realpath` is here
      # because Bootsnap asks for it before loading a YAML or JSON file through its own C code.
      %i[read binread readlines foreach copy_stream sysopen].each { put_in_front(IO.singleton_class, _1, read) }
      %i[stat lstat mtime size realpath realdirpath].each { put_in_front(File.singleton_class, _1, read) }

      [File, FileTest].each do |owner|
        %i[exist? file? directory? readable? symlink? size? zero? empty?].each do |name|
          put_in_front(owner.singleton_class, name, asked) if owner.respond_to?(name)
        end
      end
      put_in_front(Dir.singleton_class, :exist?, asked)

      put_in_front(Dir.singleton_class, :glob, "::Pitstop::Record.files_listed(args.first, options[:base])")
      put_in_front(Dir.singleton_class, :[], "::Pitstop::Record.files_listed(args, options[:base])")
      %i[children entries each_child foreach open empty?].each { put_in_front(Dir.singleton_class, _1, folder) }
      put_in_front(Dir, :initialize, folder)
    ensure
      $VERBOSE = quiet
    end
  end
end

Coverage.setup(lines: true, eval: true)
Coverage.resume
Process.singleton_class.prepend(Pitstop::Record::ForkWatch) if Process.respond_to?(:_fork)
Pitstop::Record.watch_listing
Pitstop::Record.watch_files
at_exit { Pitstop::Record.names! } # registered first, so it runs last, after the tests
if Pitstop::Record.child?
  # Started from inside a test: everything this process runs belongs to that test.
  at_exit { Pitstop::Record.child_finished }
  Pitstop::Watch.frameworks(simplecov: ->(simplecov) { simplecov.singleton_class.prepend(Pitstop::Record::SimpleCovOff) })
else
  # Forked workers that end without returning to Minitest.run still get their last file written.
  at_exit { Pitstop::Record.flush_group }
  Pitstop::Record.watch_for_frameworks
end
