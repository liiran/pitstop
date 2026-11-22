require "json"
require "zlib"
require "set"

module Pitstop
  # Which lines of which files each test ran, built from the per-process files `pitstop record`
  # writes. Saved as .pitstop/map.json.gz:
  #
  #   {"version": 1, "commit": "a1b2c3d…", "dirty": ["app/models/cart.rb"],
  #    "tests": [["CartTest#test_total", "test/models/cart_test.rb", 4, "pass", 12.5], …],
  #    "boot":  {"app/models/cart.rb": [[1, 4], [9, 9]]},
  #    "files": {"app/models/cart.rb": [[[[5, 5]], [0, 7, 9]], …]}}
  #
  # Under "files", tests that ran exactly the same lines of a file share one entry: the lines,
  # then the test numbers (positions in "tests"). That keeps big suites' maps small.
  class Map
    VERSION = 1
    Test = Struct.new(:index, :id, :file, :line, :status, :ms) do
      def failed? = status != "pass"
    end

    attr_reader :commit, :dirty, :tests, :boot, :files, :framework

    # Project files loaded before coverage started (`bundle exec` loads a gem's gemspec, and
    # whatever it requires, first). No test is linked to them, so a change to one runs everything.
    attr_reader :unseen

    # Raised when the recording can't give a correct map.
    class Error < StandardError; end

    # Problems found while merging that don't stop the map from being saved, but would make it
    # miss tests. `pitstop record` prints them.
    attr_reader :warnings

    def self.build(shard_dir, commit:, dirty: [])
      records = Dir[File.join(shard_dir, "*.jsonl")].sort.flat_map do |path|
        File.foreach(path).map { JSON.parse(_1) }
      end
      error = records.find { _1["kind"] == "error" }
      raise Error, error["message"] if error
      raise Error, "no tests were recorded (did the test command run any?)" if records.none? { _1["kind"] == "test" }

      by_kind = records.group_by { _1["kind"] }
      tests = {}
      by_kind.fetch("test", []).each { tests[_1["id"]] = _1 } # a test recorded twice (a retry) keeps its last run
      # The framework's final word on a result, decided after the test's own record was written.
      by_kind.fetch("status", []).each { tests[_1["id"]]&.store("status", _1["status"]) }
      list = tests.values
      number = list.each_with_index.to_h { |r, i| [r["id"], i] }
      in_file = Hash.new { |h, k| h[k] = [] }
      list.each_with_index { |r, i| in_file[r["file"]] << i }

      by_file = Hash.new { |h, k| h[k] = Hash.new { |hh, kk| hh[kk] = [] } }
      add = ->(cov, idx) { cov.each { |path, ranges| by_file[path][ranges].concat(idx) } }
      list.each_with_index { |r, i| add.(r["cov"], [i]) if r["cov"] }
      # Recorded per test file: every test in the file shares the file's lines.
      by_kind.fetch("group", []).each { |g| add.(g["cov"], g["tests"].filter_map { number[_1] }) }
      # Setup shared by a spec file (before(:context)): every test in that file.
      by_kind.fetch("between", []).each { |b| add.(b["cov"], in_file[b["file"]]) if in_file.key?(b["file"]) }
      # A subprocess or fork a test started.
      by_kind.fetch("child", []).each { |c| add.(c["cov"], [number[c["test"]]]) if number[c["test"]] }

      boot = Hash.new { |h, k| h[k] = [] }
      (by_kind.fetch("boot", []) + by_kind.fetch("worker_boot", [])).each do |r|
        r["cov"].each { |path, ranges| boot[path].concat(ranges) }
      end

      unseen = by_kind.fetch("boot", []).flat_map { _1["unseen"] || [] }.uniq.sort
      map = new(
        "version" => VERSION, "commit" => commit, "dirty" => dirty, "unseen" => unseen,
        "framework" => list.first["framework"],
        "tests" => list.map { [_1["id"], _1["file"], _1["line"], _1["status"], _1["ms"]] },
        "boot" => boot.transform_values { merge_ranges(_1) },
        "files" => by_file.transform_values { |sets| sets.map { |ranges, idx| [ranges, idx.uniq.sort] } }
      )
      map.check(by_kind)
      map
    end

    def check(by_kind)
      summaries = by_kind.fetch("summary", [])
      ran = summaries.sum { _1["ran"] }
      if summaries.empty?
        @warnings << "couldn't confirm every test was recorded: the test run never reported its total (did it stop early?)"
      elsif ran > tests.size
        named = summaries.flat_map { _1["unrecorded"] || [] }
        @warnings << "#{ran - tests.size} of #{ran} tests ran without being recorded, so they'll only run when their own test file " \
                     "changes#{": #{named.first(5).join(', ')}#{', …' if named.size > 5}" unless named.empty?}"
      end

      return if unseen.empty?

      one = unseen.size == 1
      @warnings << "#{unseen.size} project #{one ? 'file' : 'files'} loaded before coverage started, so no test is linked " \
                   "to #{one ? 'it' : 'them'} and changing #{one ? 'it' : 'one'} runs every test: " \
                   "#{unseen.first(5).join(', ')}#{', …' if unseen.size > 5}. `bundle exec` loads a gem's gemspec " \
                   "(and what it requires) first; anything more means something else loads code before Pitstop " \
                   "(another RUBYOPT -r, a preloader such as Spring)."
    end

    def self.merge_ranges(ranges)
      ranges.sort.each_with_object([]) do |(first, last), out|
        if out.last && first <= out.last[1] + 1
          out.last[1] = [out.last[1], last].max
        else
          out << [first, last]
        end
      end
    end

    def self.load(path)
      data = Zlib::GzipReader.open(path) { JSON.parse(_1.read) }
      raise Error, "#{path} is from another version of Pitstop: run `pitstop record` again" unless data["version"] == VERSION

      new(data)
    end

    def initialize(data)
      @data = data
      @commit = data["commit"]
      @dirty = data["dirty"] || []
      @framework = data["framework"]
      @tests = data["tests"].each_with_index.map { |(id, file, line, status, ms), i| Test.new(i, id, file, line, status, ms) }
      @boot = data["boot"]
      @files = data["files"]
      @unseen = data["unseen"] || []
      @warnings = []
    end

    def save(path)
      dir = File.dirname(path)
      Dir.mkdir(dir) unless Dir.exist?(dir)
      Zlib::GzipWriter.open(path) { _1.write(JSON.generate(@data)) }
    end

    def covered?(path) = @files.key?(path)

    # Test numbers of the tests that ran any line of `path` (or, given `lines`, any of those lines).
    def tests_touching(path, lines = nil)
      found = Set.new
      @files.fetch(path, []).each do |ranges, idx|
        found.merge(idx) if lines.nil? || ranges.any? { |first, last| first <= lines.end && last >= lines.begin }
      end
      found
    end

    def ran_during_boot?(path, lines)
      @boot.fetch(path, []).any? { |first, last| first <= lines.end && last >= lines.begin }
    end

    def tests_in_file(path) = @tests.select { _1.file == path }.map(&:index).to_set
  end
end
