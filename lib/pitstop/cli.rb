require "optparse"
require "json"
require "fileutils"
require "shellwords"
require "set"
require_relative "version"
require_relative "watch"
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
      # The real folder, as Ruby reports the files it loads from it.
      @root = File.realpath(root)
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
      warn(e.message)
      64
    rescue Git::Error, Map::Error => e
      warn(e.message)
      1
    rescue Interrupt
      130 # stopped with Ctrl-C, like the test command it was running
    end

    private

    attr_reader :root

    def pitstop_dir = File.join(root, ".pitstop")

    def map_path = File.join(pitstop_dir, "map.json.gz")

    # Everything Pitstop writes goes in .pitstop/, which keeps itself out of git: a map is made
    # for one commit on one machine's checkout, and is not meant to be committed by accident.
    def make_pitstop_dir
      return if Dir.exist?(pitstop_dir)

      Dir.mkdir(pitstop_dir)
      File.write(File.join(pitstop_dir, ".gitignore"), "*\n")
    end

    # --- record ----------------------------------------------------------------------------------

    def record
      command = command_from(@argv)
      git = Git.new(root)
      commit = git.head
      make_pitstop_dir
      run_dir = File.join(pitstop_dir, "runs", "#{Time.now.strftime('%Y%m%d-%H%M%S')}-#{Process.pid}")
      FileUtils.mkdir_p(run_dir)
      env = hook_env("record").merge("PITSTOP_OUT" => run_dir)
      say("Pitstop: recording `#{shown(command)}` at #{commit[0, 7]}")
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      ok = start(env, command)
      seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      map = Map.build(run_dir, commit:, dirty: git.dirty_paths.reject { _1.start_with?(".pitstop/") || _1 == ".pitstop" })
      map.save(map_path)
      map.warnings.each { warn("warning: #{_1}") }
      failed = map.tests.count(&:failed?)
      say("Pitstop: mapped #{map.tests.size} tests over #{map.files.size} files in #{seconds.round}s" \
          "#{" (#{failed} didn't pass; they'll always run)" if failed.positive?}. Saved #{relative(map_path)}")
      ok ? 0 : 1
    ensure
      FileUtils.rm_rf(run_dir) if run_dir && ENV["PITSTOP_KEEP_RUNS"] != "1"
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
      command = command_from([])
      if json
        @out.puts(JSON.pretty_generate(as_json(map, selection, command)))
      else
        print_reasons(map, selection, explain:)
        if selection.all?
          say("Would run all #{map.tests.size} tests: #{selection.run_all}")
        else
          plan = plan_for(map, selection, command)
          say("Would run #{describe(plan, map)}")
          plan.tests.each { |t| say("    #{t.id}  #{t.file}:#{t.line}") } if explain
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
        say("Running all #{map.tests.size} tests: #{selection.run_all}")
        return start({ "PITSTOP" => "run", "PITSTOP_TEST" => nil }, command) ? 0 : 1
      end

      plan = plan_for(map, selection, command)
      if plan.empty?
        say("Nothing to run: none of your changes can affect a test.")
        return 0
      end

      make_pitstop_dir
      ran_dir = File.join(pitstop_dir, "ran-#{Process.pid}")
      FileUtils.rm_rf(ran_dir)
      FileUtils.mkdir_p(ran_dir)
      selection_file = File.join(ran_dir, "selection.txt")
      File.binwrite(selection_file, plan.files.map { "file #{Watch.escape(_1)}\n" }.join +
                                    plan.tests.map { "test #{Watch.escape(_1.id)}\n" }.join)
      narrowed = narrow(command, map.framework, plan)
      env = hook_env("filter").merge("PITSTOP_SELECTION" => selection_file, "PITSTOP_OUT" => ran_dir)
      say("Running #{describe(plan, map)}")
      ok = start(env, narrowed)
      checked = check_ran(plan, read_ran(ran_dir))
      return 1 unless ok

      checked ? 0 : 3
    ensure
      FileUtils.rm_rf(ran_dir) if ran_dir
    end

    # Runs the test command and waits for it. The command is a list of words and is started
    # directly, never through a shell: `["rspec", "a;b"]` passes "a;b" to rspec as it is.
    def start(env, command)
      @out.flush
      pid = begin
        Process.spawn(env, [command.first, command.first], *command.drop(1), chdir: root)
      rescue SystemCallError
        hint = command.size == 1 && command.first.include?(" ") ? " (give the command as separate words: -- #{command.first})" : ""
        raise ArgumentError, "couldn't start `#{shown(command)}`#{hint}"
      end
      _, status = Process.wait2(pid)
      pid = nil
      status.success?
    ensure
      stop(pid) if pid
    end

    # Pitstop is being stopped (Ctrl-C, or a CI job cancelled) while the test command still runs:
    # stop the command too, so no test run is left going with nobody waiting for it.
    def stop(pid)
      Process.kill(Gem.win_platform? ? "KILL" : "TERM", pid)
      50.times do
        return if Process.wait(pid, Process::WNOHANG)

        sleep 0.1
      end
      Process.kill("KILL", pid)
      Process.wait(pid)
    rescue SystemCallError
      nil # already gone
    end

    # The tests to run, leaving out tests whose file is gone (a failed test in a deleted file) and
    # changed test files the test command wouldn't run by itself.
    def plan_for(map, selection, command)
      left_out = left_out(map, selection, command)
      left_out.each do |file|
        say("  #{file}  left out: `bin/rails test` doesn't run this folder (it has its own command)")
      end
      files = (selection.files - left_out).select { File.file?(File.join(root, _1)) }.to_set
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
      extra = if framework == "rspec" && command.any? { File.basename(_1, ".*") == "rspec" } then rspec_args(plan)
              elsif rails_test?(command, framework) then plan.test_files
              end
      return command unless extra && extra.all? { passable?(_1) }

      # A file whose name starts with a dash would be read as an option.
      command + extra.map { _1.start_with?("-") ? "./#{_1}" : _1 }
    end

    # `bin/rails test` with no file names, which Pitstop narrows by adding the files it needs.
    def rails_test?(command, framework)
      framework == "minitest" && command.last == "test" && command.any? { File.basename(_1, ".*") == "rails" }
    end

    # Changed test files that `bin/rails test` wouldn't run by itself. With no file names it
    # leaves some folders out (browser tests in test/system, most of all), and naming a file from
    # one of them would run tests the whole suite doesn't run. A file with tests in the map stays:
    # the recorded command ran it.
    RAILS_LEAVES_OUT = "test/{system,dummy,fixtures}/**/*_test.rb"

    def left_out(map, selection, command)
      return [] unless rails_test?(command, map.framework)

      pattern = ENV.fetch("DEFAULT_TEST_EXCLUDE", RAILS_LEAVES_OUT)
      recorded = map.tests.map(&:file).to_set
      selection.files.select { File.fnmatch?(pattern, _1, Rules::FLAGS) && !recorded.include?(_1) }.sort
    end

    # Can this file name be handed to the test command as it is? On Windows, commands such as
    # `bundle` and `rspec` are batch files, and cmd.exe rewrites some characters in their arguments
    # (%NAME% becomes a variable's value, ^ disappears). With a name like that the command isn't
    # narrowed: for Minitest the filter still runs only the selected tests, and RSpec runs them all.
    def passable?(arg) = !Gem.win_platform? || arg.match?(%r{\A[\p{Alnum} _\-./\\:,@+=~#\[\]()']+\z})

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
        File.foreach(path, chomp: true, mode: "rb", encoding: "UTF-8") do |line|
          id, file, status = line.split("\t").map { Watch.unescape(_1) }
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
      say(summary)
      silent.each { warn("warning: no tests ran from #{_1}") }
      if ran.empty?
        warn("no tests ran at all, so nothing was checked. Is the test command right, and does it load Pitstop's RUBYOPT?")
        return false
      end
      return true if missing.empty?

      warn("#{missing.size} selected #{missing.size == 1 ? 'test' : 'tests'} didn't run, so this run doesn't " \
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
          data = read_yaml(path) || {}
          raise ArgumentError, ".pitstop.yml should be a list of settings like `ignore: [\"docs/**\"]`" unless data.is_a?(Hash)

          unknown = data.keys - CONFIG_KEYS
          raise ArgumentError, ".pitstop.yml: unknown setting #{unknown.first.inspect} (known: #{CONFIG_KEYS.join(', ')})" unless unknown.empty?

          data.each do |key, value|
            next if key == "command" ? (value.is_a?(String) && !value.strip.empty?) || words?(value) : string_list?(value)

            raise ArgumentError, ".pitstop.yml: #{key} should be a list of #{key == 'command' ? 'words' : 'file patterns'}"
          end
          data
        else
          {}
        end
      end
    end

    # Plain settings only: strings, lists and so on. YAML that names a Ruby class to build, or
    # that repeats itself with aliases, is refused.
    def read_yaml(path)
      require "yaml"
      YAML.safe_load_file(path)
    rescue Psych::Exception => e
      raise ArgumentError, ".pitstop.yml can't be read: #{e.message.sub(/\A\(.*?\): /, '').lines.first.to_s.strip}"
    end

    def string_list?(value) = value.is_a?(Array) && value.all?(String)

    def words?(value) = string_list?(value) && !value.empty? && value.none?(&:empty?)

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

    # Loads one of Pitstop's hook files ("record" or "filter") into the test process before
    # anything else. Its folder goes in RUBYLIB, not in RUBYOPT as -I: RUBYOPT is split on spaces,
    # and Pitstop may be installed under a folder with a space in its name. PITSTOP tells the
    # project's own test setup which of the two is running.
    def hook_env(mode)
      lib = File.expand_path("..", __dir__)
      {
        "RUBYLIB" => [lib, ENV["RUBYLIB"]].compact.reject(&:empty?).join(File::PATH_SEPARATOR),
        "RUBYOPT" => "-rpitstop/#{mode} #{ENV['RUBYOPT']}".strip,
        "PITSTOP" => mode == "filter" ? "run" : mode, "PITSTOP_ROOT" => root, "PITSTOP_TEST" => nil
      }
    end

    def print_reasons(map, selection, explain:)
      say("Pitstop: map from #{map.commit[0, 7]}, #{map.tests.size} tests")
      reasons = explain ? selection.reasons : selection.reasons.reject { _1.tests.zero? && !_1.all }
      width = reasons.map { _1.path.to_s.size }.max.to_i
      reasons.each do |r|
        count = r.all ? "all tests" : "#{r.tests} #{r.tests == 1 ? 'test' : 'tests'}"
        say("  #{(r.path || '(map)').ljust(width)}  #{r.what}  → #{count}")
      end
    end

    # One line to the terminal. File and test names come from the repository, and a name can hold
    # characters that drive a terminal (colours, cursor moves, text-direction marks), so those are
    # shown as codes like \e instead of being sent.
    def say(line) = @out.puts(printable(line))

    def warn(line) = @err.puts(printable("pitstop: #{line}"))

    UNPRINTABLE = /[\p{Cc}؜‎‏‪-‮⁦-⁩]/

    def printable(text) = text.to_s.scrub("?").gsub(UNPRINTABLE) { _1.dump[1..-2] }

    def as_json(map, selection, command)
      left_out = selection.all? ? [] : left_out(map, selection, command)
      {
        map_commit: map.commit, run_all: selection.run_all,
        tests: selection.all? ? map.tests.map(&:id) : selection.tests.sort.map { map.tests[_1].id },
        files: selection.files.to_a.sort - left_out, left_out:,
        reasons: selection.reasons.map(&:to_h)
      }
    end

    def shown(command) = command.map { _1.include?(" ") ? _1.inspect : _1 }.join(" ")

    def relative(path) = path.delete_prefix("#{root}/")
  end
end
