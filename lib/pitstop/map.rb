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

    def self.build(shard_dir, commit:, dirty: [])
      records = Dir[File.join(shard_dir, "*.jsonl")].sort.flat_map do |path|
        File.foreach(path).map { JSON.parse(_1) }
      end
      raise ArgumentError, "no recorded tests in #{shard_dir}" if records.none? { _1["kind"] == "test" }

      tests = {}
      boot = Hash.new { |h, k| h[k] = [] }
      by_file = Hash.new { |h, k| h[k] = Hash.new { |hh, kk| hh[kk] = [] } }
      records.each do |r|
        if r["kind"] == "test"
          tests[r["id"]] = r # a test recorded twice (a retry) keeps its last run
        else
          r["cov"].each { |path, ranges| boot[path].concat(ranges) }
        end
      end
      list = tests.values
      list.each_with_index do |r, i|
        r["cov"].each { |path, ranges| by_file[path][ranges] << i }
      end
      new(
        "version" => VERSION, "commit" => commit, "dirty" => dirty,
        "framework" => list.first["framework"],
        "tests" => list.map { [_1["id"], _1["file"], _1["line"], _1["status"], _1["ms"]] },
        "boot" => boot.transform_values { merge_ranges(_1) },
        "files" => by_file.transform_values { |sets| sets.map { |ranges, idx| [ranges, idx] } }
      )
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
      raise ArgumentError, "#{path} is map version #{data['version']}, expected #{VERSION}" unless data["version"] == VERSION

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
