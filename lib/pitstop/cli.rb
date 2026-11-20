require "optparse"
require "json"
require "fileutils"
require_relative "version"
require_relative "git"
require_relative "map"
require_relative "rules"
require_relative "selector"

module Pitstop
  # pitstop record [-- command]   run the whole suite once, noting which code each test runs
  # pitstop list [--explain]      show which tests your changes can affect, without running them
  class CLI
    USAGE = <<~TEXT
      Usage:
        pitstop record [-- <test command>]   Run every test once and save the map (.pitstop/map.json.gz)
        pitstop list [--explain] [--json]    Show the tests your changes since the map can affect

      The test command defaults to `bin/rails test`, or `bundle exec rspec` in a project with spec/.
    TEXT

    def self.start(argv, out: $stdout, err: $stderr) = new(argv, out:, err:).run

    def initialize(argv, out:, err:)
      @argv = argv.dup
      @out = out
      @err = err
    end

    def run
      case @argv.shift
      when "record" then record
      when "list" then list
      when "--version", "-v" then @out.puts(VERSION) || 0
      when nil, "help", "--help", "-h" then @out.puts(USAGE) || 0
      else
        @err.puts(USAGE)
        64
      end
    rescue OptionParser::ParseError, ArgumentError, Git::Error => e
      @err.puts("pitstop: #{e.message}")
      64
    end

    private

    def root = @root ||= Dir.pwd

    def map_path = File.join(root, ".pitstop", "map.json.gz")

    def record
      command = @argv.first == "--" ? @argv.drop(1) : @argv
      command = default_command if command.empty?
      git = Git.new(root)
      commit = git.head
      run_dir = File.join(root, ".pitstop", "runs", Time.now.strftime("%Y%m%d-%H%M%S"))
      FileUtils.mkdir_p(run_dir)
      env = {
        "RUBYOPT" => "-I#{File.expand_path('..', __dir__)} -rpitstop/record #{ENV['RUBYOPT']}".strip,
        "PITSTOP_OUT" => run_dir, "PITSTOP_ROOT" => root
      }
      @out.puts("Pitstop: recording `#{command.join(' ')}` at #{commit[0, 7]}")
      @out.flush
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      ok = system(env, *command, chdir: root)
      seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      map = Map.build(run_dir, commit:, dirty: git.dirty_paths - [".pitstop"])
      map.save(map_path)
      failed = map.tests.count(&:failed?)
      @out.puts("Pitstop: mapped #{map.tests.size} tests over #{map.files.size} files in #{seconds.round}s" \
                "#{" (#{failed} didn't pass; they'll always run)" if failed.positive?}. Saved #{relative(map_path)}")
      ok ? 0 : 1
    end

    def default_command
      if File.exist?(File.join(root, "spec")) && !File.exist?(File.join(root, "test"))
        %w[bundle exec rspec]
      elsif File.exist?(File.join(root, "bin", "rails"))
        [Gem.ruby, "bin/rails", "test"]
      else
        %w[bundle exec rake test]
      end
    end

    def list
      explain = json = false
      OptionParser.new do |o|
        o.on("--explain") { explain = true }
        o.on("--json") { json = true }
      end.parse!(@argv)
      raise ArgumentError, "no map yet: run `pitstop record` first" unless File.exist?(map_path)

      map = Map.load(map_path)
      selection = select(map)
      if json
        @out.puts(JSON.pretty_generate(as_json(map, selection)))
      else
        print_selection(map, selection, explain:)
      end
      0
    end

    def select(map)
      git = Git.new(root)
      unless git.commit?(map.commit)
        reason = Selector::Reason.new(path: nil, what: "the map's commit #{map.commit[0, 7]} isn't in this repo", tests: map.tests.size, all: true)
        return Selector::Selection.new(tests: Set.new, files: Set.new, reasons: [reason], run_all: reason.what)
      end

      Selector.new(
        map:, changes: git.changes_since(map.commit),
        old_source: ->(path) { git.show(map.commit, path) },
        new_source: ->(path) { full = File.join(root, path); File.file?(full) ? File.read(full) : nil }
      ).select
    end

    def print_selection(map, selection, explain:)
      @out.puts("Pitstop: map from #{map.commit[0, 7]}, #{map.tests.size} tests")
      reasons = explain ? selection.reasons : selection.reasons.reject { _1.tests.zero? && !_1.all }
      width = reasons.map { _1.path.to_s.size }.max.to_i
      reasons.each do |r|
        count = r.all ? "all tests" : "#{r.tests} #{r.tests == 1 ? 'test' : 'tests'}"
        @out.puts("  #{(r.path || '(map)').ljust(width)}  #{r.what}  → #{count}")
      end
      if selection.all?
        @out.puts("Would run all #{map.tests.size} tests: #{selection.run_all}")
      else
        n = selection.tests.size
        extra = selection.files.empty? ? "" : ", plus whole files: #{selection.files.to_a.join(', ')}"
        @out.puts("Would run #{n} of #{map.tests.size} tests (#{(100.0 * n / map.tests.size).round(1)}%)#{extra}")
        if explain
          selection.tests.sort.each { |i| t = map.tests[i]; @out.puts("    #{t.id}  #{t.file}:#{t.line}") }
        end
      end
    end

    def as_json(map, selection)
      {
        map_commit: map.commit, run_all: selection.run_all,
        tests: selection.all? ? map.tests.map(&:id) : selection.tests.sort.map { map.tests[_1].id },
        files: selection.files.to_a,
        reasons: selection.reasons.map(&:to_h)
      }
    end

    def relative(path) = path.delete_prefix("#{root}/")
  end
end
