require "json"
require "zlib"
require "set"

module Pitstop
  # Which lines of which files each test ran, built from the per-process files `pitstop record`
  # writes. Saved as .pitstop/map.json.gz:
  #
  #   {"version": 2, "commit": "a1b2c3d…", "dirty": ["app/models/cart.rb"],
  #    "tests": [["CartTest#test_total", "test/models/cart_test.rb", 4, "pass", 12.5], …],
  #    "boot":  {"app/models/cart.rb": [[1, 4], [9, 9]]},
  #    "files": {"app/models/cart.rb": [[[[5, 5]], [0, 7, 9]], …]},
  #    "methods": ["==", "total", "to_s", …], "modules": {"Cart": "i", "Price": ""}}
  #
  # Under "files", tests that ran exactly the same lines of a file share one entry: the lines,
  # then the test numbers (positions in "tests"). That keeps big suites' maps small.
  # "methods" and "modules" are what the recorder noted about names (Record.names!).
  #
  # "opened" and "order" are about files a test depends on without running a line of them:
  #
  #    "opened": {"reads": {"docs/notes.md": [0, 4]},        tests that read this file
  #               "lists": {"docs/*.md": [2], "bin/setup": [5]},   tests that asked which files
  #                                           match a pattern, or whether one file exists
  #               "boot_reads": [...], "boot_lists": [...],  the same, while the app was starting
  #               "file_reads": {"test/x_test.rb": [...]},   by a test file's own code as it
  #               "file_lists": {...}},                      loaded
  #    "order":  [[0, 2, 1], [3]]             each test process's tests, in the order they ran
  class Map
    VERSION = 3
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
      shards = Dir[File.join(shard_dir, "*.jsonl")].sort.map { |path| File.foreach(path).map { JSON.parse(_1) } }
      records = shards.flatten(1)
      error = records.find { _1["kind"] == "error" }
      raise Error, error["message"] if error
      if records.none? { _1["kind"] == "test" }
        raise Error, "no tests were recorded. Did the test command run any, on Ruby 3.2 or newer (not JRuby or TruffleRuby)?"
      end

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

      # A map that links no test to any file would pick nothing for every change, and look safe.
      if by_file.empty? && boot.empty?
        raise Error, "#{list.size} tests were recorded, but none of them ran a file in this folder. " \
                     "Run `pitstop record` from the project's own folder (where its code and tests are)."
      end

      unseen = by_kind.fetch("boot", []).flat_map { _1["unseen"] || [] }.uniq.sort
      # One file per process (fewer when processes had the same code loaded): everything any of
      # them had counts.
      names = Dir[File.join(shard_dir, "names-*.json")].sort.map { JSON.parse(File.read(_1)) }
      map = new({
        "version" => VERSION, "commit" => commit, "dirty" => dirty, "unseen" => unseen,
        "framework" => list.first["framework"],
        "tests" => list.map { [_1["id"], _1["file"], _1["line"], _1["status"], _1["ms"]] },
        "boot" => boot.transform_values { merge_ranges(_1) },
        "files" => by_file.transform_values { |sets| sets.map { |ranges, idx| [ranges, idx.uniq.sort] } },
        **opened(shards, number, in_file),
        "methods" => (names.flat_map { _1["methods"] }.uniq.sort unless names.empty?),
        "modules" => (names.map { _1["modules"] }.reduce { |all, some| all.merge(some) { |_, a, b| (a + b).chars.uniq.sort.join } } unless names.empty?)
      }.compact)
      map.check(by_kind)
      map
    end

    # Who read which file and looked for which files ("order" and "opened", described at the top).
    def self.opened(shards, number, in_file)
      order = []
      found = { "reads" => {}, "lists" => {}, "boot_reads" => [], "boot_lists" => [], "file_reads" => {}, "file_lists" => {} }
      shards.each do |records|
        ran = records.select { _1["kind"] == "test" }.filter_map { number[_1["id"]] }.uniq
        order << ran unless ran.empty?
        records.each do |record|
          who = case record["kind"]
                when "test" then [number[record["id"]]]
                when "group" then record["tests"].map { number[_1] }
                # Setup or cleanup shared by a spec file: what it read is there for all its tests.
                when "between" then in_file.key?(record["file"]) ? in_file[record["file"]] : [nil]
                when "child" then [number[record["test"]]]
                when "boot", "worker_boot" then [nil]
                else next
                end
          %w[reads lists].each do |kind|
            (record[kind] || []).each do |key|
              # Read while the app was starting, or by something no recorded test can be linked
              # to: every test may depend on it.
              next found["boot_#{kind}"] << key if who.empty? || who.include?(nil)

              (found[kind][key] ||= []).concat(who)
            end
          end
          (record["loading"] || {}).each do |test_file, opened|
            %w[reads lists].each { |kind| (found["file_#{kind}"][test_file] ||= []).concat(opened[kind] || []) }
          end
        end
      end
      %w[reads lists].each do |kind|
        found[kind].transform_values! { _1.uniq.sort }
        found["file_#{kind}"].transform_values! { _1.uniq.sort }
        found["file_#{kind}"].reject! { |_, keys| keys.empty? }
        found["boot_#{kind}"] = found["boot_#{kind}"].uniq.sort
      end
      { "order" => order, "opened" => found }
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

    # The most a map may unpack to. A real one is a few megabytes; a small file that unpacks to
    # gigabytes is not a map.
    MAX_BYTES = 1 << 30

    # The map file is data, and it may come from somewhere else (a CI artifact, a clone), so it's
    # read with a plain JSON parser and checked before use: what it says becomes arguments to git
    # and to the test command.
    def self.load(path)
      shown = path.delete_prefix("#{Dir.pwd}/")
      json = Zlib::GzipReader.open(path) { _1.read(MAX_BYTES + 1) }.to_s
      raise Error, "#{shown} is too large to be a map: run `pitstop record` again" if json.bytesize > MAX_BYTES

      data = JSON.parse(json)
      raise Error, "#{shown} isn't a Pitstop map: run `pitstop record` again" unless data.is_a?(Hash)
      raise Error, "#{shown} is from another version of Pitstop: run `pitstop record` again" unless data["version"] == VERSION

      problem = problem_with(data)
      raise Error, "#{shown} isn't a map Pitstop wrote (#{problem}): run `pitstop record` again" if problem

      new(data)
    rescue Zlib::Error, JSON::ParserError, EOFError, EncodingError => e
      raise Error, "#{shown} can't be read (#{e.message.lines.first.to_s.strip[0, 80]}): run `pitstop record` again"
    end

    COMMIT = /\A\h{40}(\h{24})?\z/
    STATUSES = %w[pass fail skip].freeze

    # What's wrong with a map's contents, in a few words, or nil.
    def self.problem_with(data)
      return "its commit" unless data["commit"].is_a?(String) && data["commit"].match?(COMMIT)

      tests = data["tests"]
      return "its tests" unless tests.is_a?(Array) && tests.all? { test?(_1) }
      return "its framework" unless data["framework"].nil? || data["framework"].is_a?(String)

      %w[dirty unseen].each do |key|
        list = data[key] || []
        return "its #{key} files" unless list.is_a?(Array) && list.all? { _1.is_a?(String) && !_1.include?("\0") }
      end
      return "its unseen files" unless (data["unseen"] || []).all? { inside?(_1) }

      boot = data["boot"]
      return "its boot lines" unless boot.is_a?(Hash) && boot.all? { |path, ranges| inside?(path) && ranges?(ranges) }

      methods = data["methods"]
      return "its method names" unless methods.nil? || (methods.is_a?(Array) && methods.all?(String))

      modules = data["modules"]
      unless modules.nil? || (modules.is_a?(Hash) && modules.all? { |name, marks| name.is_a?(String) && marks.is_a?(String) && marks.match?(/\A[iIcC]*\z/) })
        return "its classes"
      end

      return "its record of files read" unless opened?(data["order"], data["opened"], tests.size)

      files = data["files"]
      return "its files" unless files.is_a?(Hash)

      files.each do |path, sets|
        return "its files" unless inside?(path) && sets.is_a?(Array)

        sets.each do |set|
          return "its files" unless set.is_a?(Array) && set.size == 2 && ranges?(set[0])

          numbers = set[1]
          return "its files" unless numbers.is_a?(Array) && numbers.all?(Integer)
          return "its files" unless numbers.empty? || (numbers.min >= 0 && numbers.max < tests.size)
        end
      end
      nil
    end

    def self.test?(test)
      test.is_a?(Array) && test[0].is_a?(String) && (test[1].nil? || inside?(test[1])) &&
        (test[2].nil? || test[2].is_a?(Integer)) && STATUSES.include?(test[3]) && (test[4].nil? || test[4].is_a?(Numeric))
    end

    def self.opened?(order, opened, tests)
      return true if order.nil? && opened.nil?

      numbers = ->(list) { list.is_a?(Array) && list.all? { _1.is_a?(Integer) && _1 >= 0 && _1 < tests } }
      names = ->(list) { list.is_a?(Array) && list.all? { _1.is_a?(String) && !_1.include?("\0") } }
      by_test = ->(table) { table.is_a?(Hash) && table.all? { |key, list| names.([key]) && numbers.(list) } }
      files = ->(table) { by_test.(table) && table.each_key.all? { inside?(_1) } }
      by_file = ->(table) { table.is_a?(Hash) && table.all? { |file, list| inside?(file) && names.(list) } }
      order.is_a?(Array) && order.all?(&numbers) && opened.is_a?(Hash) &&
        files.(opened["reads"]) && by_test.(opened["lists"]) && names.(opened["boot_reads"]) && names.(opened["boot_lists"]) &&
        by_file.(opened["file_reads"]) && by_file.(opened["file_lists"])
    end

    def self.ranges?(ranges)
      ranges.is_a?(Array) && ranges.all? { _1.is_a?(Array) && _1.size == 2 && _1[0].is_a?(Integer) && _1[1].is_a?(Integer) }
    end

    # A path inside the project's folder: relative, never climbing out of it. The recorder only
    # ever writes such paths, and a test file's path is handed to the test command.
    def self.inside?(path)
      path.is_a?(String) && !path.empty? && !path.start_with?("/") && !path.match?(/\A[A-Za-z]:|\0/) &&
        !path.split(%r{[/\\]}).include?("..")
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
      @methods = data["methods"]&.to_set
      @modules = data["modules"]
      @order = data["order"]
      @opened = data["opened"]
      @warnings = []
    end

    # The tests that depend on a file without running a line of it. `all`: something read it
    # while the app was starting, so every test may. `tests`: test numbers. `files`: test files
    # whose own top-level code read it as they loaded (they run whole).
    Dependents = Struct.new(:all, :tests, :files) do
      def none? = !all && tests.empty? && files.empty?
    end

    LISTED = File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH

    # Who read this file: its contents matter to them. `onward`: also every test that ran after
    # a reader in the same process, because what was read may have stayed in memory (a constant,
    # a cache) and been used without reading the file again.
    def readers(path, onward:) = dependents("reads", onward) { _1 == path }

    # Who asked which files exist, in a way this file's being there answers: it matched a pattern
    # they listed (`Dir["docs/*.md"]`), or they checked for it by name. `folders`: the folders
    # above it that appear or vanish with it, which answer such questions too (`Dir["docs/*"]`
    # lists a new `docs/guides` when its first file is added). `boot: false` leaves out what
    # was asked while the app was starting.
    def listers(path, folders, onward:, boot: true)
      names = [path, *folders]
      dependents("lists", onward, boot:) { |pattern| names.any? { File.fnmatch?(pattern.chomp("/"), _1, LISTED) } }
    end

    def dependents(kind, onward, boot: true, &match)
      return Dependents.new(false, Set.new, []) unless @opened
      return Dependents.new(true, Set.new, []) if boot && @opened["boot_#{kind}"].any?(&match)

      tests = Set.new
      @opened[kind].each { |key, readers| tests.merge(readers) if match.(key) }
      tests = from_first(tests) if onward
      Dependents.new(false, tests, @opened["file_#{kind}"].select { |_, keys| keys.any?(&match) }.keys)
    end

    # These tests, and every test that ran after one of them in the same process.
    def from_first(tests)
      @place ||= @order.each_with_index.with_object({}) do |(ran, process), place|
        ran.each_with_index { |test, position| place[test] ||= [process, position] }
      end
      first = {}
      tests.each do |test|
        process, position = @place[test]
        first[process] = position if process && (first[process].nil? || position < first[process])
      end
      first.each_with_object(tests.dup) { |(process, position), all| all.merge(@order[process][position..]) }
    end

    # Did any class or module have a method of this name while the map was recorded: the
    # project's own, its gems', Ruby's? A recording that kept no names can't say no.
    def method?(name) = @methods.nil? || @methods.include?(name)

    # What the recorder noted about one of the project's classes or modules, by name: whose of
    # its methods some code listed ("i" public ones, "I" private ones, "c" and "C" the same for
    # the class's own methods). nil if it wasn't a class or module of the project then.
    def module_marks(name) = @modules&.[](name)

    # Written beside the map and then moved into place, so a reader never sees half a map, and
    # whatever was at `path` (even a link to another file) is replaced, never written through.
    def save(path)
      dir = File.dirname(path)
      Dir.mkdir(dir) unless Dir.exist?(dir)
      partial = "#{path}.#{Process.pid}.tmp"
      Zlib::GzipWriter.open(partial) { _1.write(JSON.generate(@data)) }
      File.rename(partial, path)
    ensure
      File.delete(partial) if partial && File.exist?(partial)
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
