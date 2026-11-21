require "optparse"
require "json"
require "fileutils"
require "shellwords"
require "set"
require_relative "version"
require_relative "git"
require_relative "map"
require_relative "rules"
require_relative "selector"

module Pitstop
  # pitstop record [-- command]   run the whole suite once, noting which code each test runs
  # pitstop list [--explain]      show which tests your changes can affect, without running them
  # pitstop run [-- command]      run only those tests
  class CLI
    USAGE = <<~TEXT
      Usage:
        pitstop record [-- <test command>]           Run every test once and save the map (.pitstop/map.json.gz)
        pitstop list [--explain] [--json]            Show the tests your changes since the map can affect
        pitstop run [--explain] [-- <test command>]  Run only those tests

      The test command is, in order: the one after `--`, `command:` in .pitstop.yml, or
      `bin/rails test`, `bundle exec rspec` (a project with spec/ and no test/) or `bundle exec rake test`.
    TEXT

    CONFIG_KEYS = (Rules::DEFAULTS.keys + ["command"]).freeze

    # What `pitstop run` will run: tests from the map, plus whole test files (new or changed ones).
    Plan = Struct.new(:tests, :files, keyword_init: true) do
      def empty? = tests.empty? && files.empty?
      def test_files = (tests.map(&:file).compact + files).uniq.sort
    end

    def self.start(argv, out: $stdout, err: $stderr) = new(argv, out:, err:).run

    def initialize(argv, out:, err:, root: Dir.pwd)
      @argv = argv.dup
      @out = out
      @err = err
      @root = File.expand_path(root)
    end

    def run
      case @argv.shift
      when "record" then record
      when "list" then list
      when "run" then run_selected
      when "--version", "-v" then @out.puts(VERSION) || 0
      when nil, "help", "--help", "-h" then @out.puts(USAGE) || 0
      else
        @err.puts(USAGE)
        64
      end
    rescue OptionParser::ParseError, ArgumentError => e
      @err.puts("pitstop: #{e.message}")
      64
    rescue Git::Error, Map::Error => e
      @err.puts("pitstop: #{e.message}")
      1
    end

    private

    attr_reader :root

    def map_path = File.join(root, ".pitstop", "map.json.gz")

    # --- record ----------------------------------------------------------------------------------

    def record
      command = command_from(@argv)
      git = Git.new(root)
      commit = git.head
      run_dir = File.join(root, ".pitstop", "runs", "#{Time.now.strftime('%Y%m%d-%H%M%S')}-#{Process.pid}")
      FileUtils.mkdir_p(run_dir)
      env = hook_env("pitstop/record").merge("PITSTOP_OUT" => run_dir, "PITSTOP_TEST" => nil)
      @out.puts("Pitstop: recording `#{shown(command)}` at #{commit[0, 7]}")
      @out.flush
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      ok = system(env, *command, chdir: root)
      raise ArgumentError, "couldn't start `#{shown(command)}`" if ok.nil?

      seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      map = Map.build(run_dir, commit:, dirty: git.dirty_paths.reject { _1.start_with?(".pitstop/") || _1 == ".pitstop" })
      map.save(map_path)
      FileUtils.rm_rf(run_dir) unless ENV["PITSTOP_KEEP_RUNS"] == "1"
      map.warnings.each { @err.puts("pitstop: warning: #{_1}") }
      failed = map.tests.count(&:failed?)
      @out.puts("Pitstop: mapped #{map.tests.size} tests over #{map.files.size} files in #{seconds.round}s" \
                "#{" (#{failed} didn't pass; they'll always run)" if failed.positive?}. Saved #{relative(map_path)}")
      ok ? 0 : 1
    end

    # --- list ------------------------------------------------------------------------------------

    def list
      explain = json = false
      OptionParser.new do |o|
        o.on("--explain") { explain = true }
        o.on("--json") { json = true }
      end.parse!(@argv)
      map = load_map
      selection = select(map)
      if json
        @out.puts(JSON.pretty_generate(as_json(map, selection)))
      else
        print_reasons(map, selection, explain:)
        if selection.all?
          @out.puts("Would run all #{map.tests.size} tests: #{selection.run_all}")
        else
          plan = plan_for(map, selection)
          @out.puts("Would run #{describe(plan, map)}")
          plan.tests.each { |t| @out.puts("    #{t.id}  #{t.file}:#{t.line}") } if explain
        end
      end
      0
    end

    # --- run -------------------------------------------------------------------------------------

    def run_selected
      explain = false
      parser = OptionParser.new { |o| o.on("--explain") { explain = true } }
      rest = @argv.first == "--" ? @argv : parser.order!(@argv)
      command = command_from(rest)
      map = load_map
      selection = select(map)
      print_reasons(map, selection, explain:)

      if selection.all?
        @out.puts("Running all #{map.tests.size} tests: #{selection.run_all}")
        @out.flush
        return system({ "PITSTOP_TEST" => nil }, *command, chdir: root) ? 0 : 1
      end

      plan = plan_for(map, selection)
      if plan.empty?
        @out.puts("Nothing to run: none of your changes can affect a test.")
        return 0
      end

      ran_dir = File.join(root, ".pitstop", "ran-#{Process.pid}")
      FileUtils.rm_rf(ran_dir)
      FileUtils.mkdir_p(ran_dir)
      selection_file = File.join(ran_dir, "selection.txt")
      File.write(selection_file, plan.files.map { "file #{_1}\n" }.join + plan.tests.map { "test #{_1.id}\n" }.join)
      narrowed, extra_env = narrow(command, map.framework, plan)
      env = hook_env("pitstop/filter").merge(extra_env).merge("PITSTOP_SELECTION" => selection_file,
                                                             "PITSTOP_OUT" => ran_dir, "PITSTOP_TEST" => nil)
      @out.puts("Running #{describe(plan, map)}")
      @out.flush
      ok = system(env, *narrowed, chdir: root)
      raise ArgumentError, "couldn't start `#{shown(narrowed)}`" if ok.nil?

      checked = check_ran(plan, read_ran(ran_dir))
      FileUtils.rm_rf(ran_dir)
      return 1 unless ok

      checked ? 0 : 3
    end

    # The tests to run, leaving out tests whose file is gone (a failed test in a deleted file).
    def plan_for(map, selection)
      files = selection.files.select { File.file?(File.join(root, _1)) }.to_set
      tests = selection.tests.sort.map { map.tests[_1] }.select do |t|
        t.file.nil? || files.include?(t.file) || File.file?(File.join(root, t.file))
      end
      Plan.new(tests:, files: files.to_a.sort)
    end

    def describe(plan, map)
      whole = plan.files.size
      n = plan.tests.size
      text = "#{n} of #{map.tests.size} tests (#{map.tests.empty? ? 0 : (100.0 * n / map.tests.size).round(1)}%)"
      text += ", plus #{whole} whole test #{whole == 1 ? 'file' : 'files'}: #{plan.files.join(', ')}" if whole.positive?
      text
    end

    # Hands the test command only the test files it needs, when it's one Pitstop knows how to
    # narrow. Any other command still runs only the selected tests (the filter drops the rest);
    # it just loads every test file first. (`rake test` isn't narrowed: Rake 13.4 reads
    # TEST=a,b as a list and older Rakes read it as one glob, so no value works for both.)
    def narrow(command, framework, plan)
      names = command.map { File.basename(_1, ".*") }
      if framework == "rspec" && names.include?("rspec")
        [command + rspec_args(plan), {}]
      elsif framework == "minitest" && names.include?("rails") && command.last == "test"
        [command + plan.test_files, {}]
      else
        [command, {}]
      end
    end

    # `spec/cart_spec.rb[1:2,1:4]` runs examples 1:2 and 1:4 of that file; a bare path runs it all.
    def rspec_args(plan)
      args = plan.files.dup
      plan.tests.group_by(&:file).each do |file, tests|
        next if file.nil? || plan.files.include?(file)

        ids = tests.map { _1.id[/\[([\d:]+)\]\z/, 1] }
        args << (ids.all? ? "#{file}[#{ids.join(',')}]" : file)
      end
      args
    end

    # {test id => [file, status]} for every test the filter saw run.
    def read_ran(dir)
      Dir[File.join(dir, "*.tsv")].each_with_object({}) do |path, ran|
        File.foreach(path, chomp: true) do |line|
          id, file, status = line.split("\t")
          ran[id] = [file, status]
        end
      end
    end

    # A run that silently ran fewer tests than it selected would look like a perfect pass, so
    # count them.
    def check_ran(plan, ran)
      expected = plan.tests.reject { plan.files.include?(_1.file) }.map(&:id)
      missing = expected.reject { ran.key?(_1) }
      from_files = ran.count { |_, (file, _)| plan.files.include?(file) }
      silent = plan.files.reject { |f| ran.any? { |_, (file, _)| file == f } }
      extra = ran.size - (expected.size - missing.size) - from_files

      summary = "Pitstop: ran #{expected.size - missing.size} of #{expected.size} selected tests"
      summary += ", plus #{from_files} from whole test files" unless plan.files.empty?
      summary += " (and #{extra} not selected)" if extra.positive?
      @out.puts(summary)
      silent.each { @err.puts("pitstop: warning: no tests ran from #{_1}") }
      if ran.empty?
        @err.puts("pitstop: no tests ran at all, so nothing was checked. Is the test command right, and does it load Pitstop's RUBYOPT?")
        return false
      end
      return true if missing.empty?

      @err.puts("pitstop: #{missing.size} selected #{missing.size == 1 ? 'test' : 'tests'} didn't run, so this run doesn't " \
                "cover your change: #{missing.first(10).join(', ')}#{', …' if missing.size > 10}")
      false
    end

    # --- shared ----------------------------------------------------------------------------------

    def load_map
      raise ArgumentError, "no map yet: run `pitstop record` first" unless File.exist?(map_path)

      Map.load(map_path)
    end

    def select(map)
      git = Git.new(root)
      unless git.commit?(map.commit)
        reason = Selector::Reason.new(path: nil, what: "the map's commit #{map.commit[0, 7]} isn't in this repo", tests: map.tests.size, all: true)
        return Selector::Selection.new(tests: Set.new, files: Set.new, reasons: [reason], run_all: reason.what)
      end

      Selector.new(
        map:, changes: git.changes_since(map.commit).reject { _1.path.start_with?(".pitstop/") }, rules: Rules.new(config.reject { _1 == "command" }),
        old_source: ->(path) { git.show(map.commit, path) },
        new_source: ->(path) { full = File.join(root, path); File.file?(full) ? File.read(full) : nil }
      ).select
    end

    # .pitstop.yml: extra patterns for each list in Rules::DEFAULTS, and the test command.
    #
    #   command: bin/rails test
    #   ignore: ["Gemfile.saas*"]
    #   global: ["app/lib/money.rb"]
    def config
      @config ||= begin
        path = File.join(root, ".pitstop.yml")
        if File.exist?(path)
          require "yaml"
          data = YAML.safe_load_file(path) || {}
          raise ArgumentError, ".pitstop.yml should be a list of settings like `ignore: [\"docs/**\"]`" unless data.is_a?(Hash)

          unknown = data.keys - CONFIG_KEYS
          raise ArgumentError, ".pitstop.yml: unknown setting #{unknown.first.inspect} (known: #{CONFIG_KEYS.join(', ')})" unless unknown.empty?

          data.each do |key, value|
            next if key == "command" ? value.is_a?(String) || string_list?(value) : string_list?(value)

            raise ArgumentError, ".pitstop.yml: #{key} should be a list of #{key == 'command' ? 'words' : 'file patterns'}"
          end
          data
        else
          {}
        end
      end
    end

    def string_list?(value) = value.is_a?(Array) && value.all?(String)

    def command_from(args)
      args = args.drop(1) if args.first == "--"
      return args unless args.empty?

      configured = config["command"]
      return configured.is_a?(String) ? Shellwords.split(configured) : configured if configured

      default_command
    end

    def default_command
      bundle = File.exist?(File.join(root, "Gemfile")) ? [Gem.ruby, "-S", "bundle", "exec"] : [Gem.ruby, "-S"]
      if File.exist?(File.join(root, "bin", "rails"))
        [Gem.ruby, "bin/rails", "test"]
      elsif File.directory?(File.join(root, "spec")) && !File.directory?(File.join(root, "test"))
        bundle + ["rspec"]
      else
        bundle + ["rake", "test"]
      end
    end

    # Loads one of Pitstop's hook files into the test process before anything else.
    def hook_env(feature)
      lib = File.expand_path("..", __dir__)
      { "RUBYOPT" => "-I#{lib} -r#{feature} #{ENV['RUBYOPT']}".strip, "PITSTOP_ROOT" => root }
    end

    def print_reasons(map, selection, explain:)
      @out.puts("Pitstop: map from #{map.commit[0, 7]}, #{map.tests.size} tests")
      reasons = explain ? selection.reasons : selection.reasons.reject { _1.tests.zero? && !_1.all }
      width = reasons.map { _1.path.to_s.size }.max.to_i
      reasons.each do |r|
        count = r.all ? "all tests" : "#{r.tests} #{r.tests == 1 ? 'test' : 'tests'}"
        @out.puts("  #{(r.path || '(map)').ljust(width)}  #{r.what}  → #{count}")
      end
    end

    def as_json(map, selection)
      {
        map_commit: map.commit, run_all: selection.run_all,
        tests: selection.all? ? map.tests.map(&:id) : selection.tests.sort.map { map.tests[_1].id },
        files: selection.files.to_a.sort,
        reasons: selection.reasons.map(&:to_h)
      }
    end

    def shown(command) = command.map { _1.include?(" ") ? _1.inspect : _1 }.join(" ")

    def relative(path) = path.delete_prefix("#{root}/")
  end
end
