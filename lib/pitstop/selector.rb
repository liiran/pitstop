require "set"
require_relative "watch"
require_relative "rules"
require_relative "unit_diff"
require_relative "git"

module Pitstop
  # Decides which tests a change can affect, from a map and the files that changed since the map's
  # commit. Every decision comes with a reason, so `pitstop list --explain` can show its work:
  #
  #   app/models/cart.rb  Cart#total changed  → 37 tests
  #   config/routes.rb    app-wide file       → all tests
  class Selector
    Reason = Struct.new(:path, :what, :tests, :all, keyword_init: true)

    Selection = Struct.new(:tests, :files, :reasons, :run_all, keyword_init: true) do
      # Test numbers from the map, plus whole test files to run (new or changed ones).
      def all? = !run_all.nil?
    end

    def initialize(map:, changes:, old_source:, new_source:, rules: Rules.new, mentioned: ->(_) { true },
                   folder_then: ->(_) { false }, folder_now: ->(_) { false }, after_readers: false)
      @map = map
      @changes = changes
      @old_source = old_source # ->(path) { content at the map's commit, or nil }
      @new_source = new_source # ->(path) { content now, or nil }
      @rules = rules
      @mentioned = mentioned # ->(word) { does it appear anywhere in the project at the map's commit? }
      @folder_then = folder_then # ->(folder) { was it there at the map's commit? }
      @folder_now = folder_now # ->(folder) { is it there now? }
      @after_readers = after_readers # also run the tests that ran after a file's reader?
    end

    def select
      @tests = Set.new
      @files = Set.new
      @reasons = []
      @run_all = nil

      @changes.each { consider(_1) }
      @map.dirty.each { |path| with_openers(path, "?") { dirty_file(path) } }
      unfinished = @map.tests.select(&:failed?).map(&:index)
      note(nil, "didn't pass when the map was made", unfinished) unless unfinished.empty?

      Selection.new(tests: @tests, files: @files, reasons: @reasons, run_all: @run_all)
    end

    private

    def consider(change)
      consider_path(change.old_path, "D") if change.renamed?
      consider_path(change.path, change.renamed? ? "A" : change.status)
    end

    def consider_path(path, status)
      verdict = @rules.classify(path)
      return outside(path, verdict) if path.start_with?("../")

      with_openers(path, status) do
        case verdict.kind
        when :ignore then note(path, verdict.reason, [])
        when :global then run_all(path, verdict.reason)
        when :test then test_file(path, status)
        when :browser
          status == "D" ? run_all(path, "browser-only file deleted") : note(path, verdict.reason, [])
        when :ruby then ruby_file(path, status)
        else other_file(path, status, verdict)
        end
      end
    end

    # Whatever the rules above say about a file, a test can depend on it without running a line
    # of it: a spec that checks the changelog's format reads the changelog, and one that makes
    # an example per file in a folder depends on which files are there. The recording noted both,
    # and those tests are added here. They are only ever added: nothing is narrowed by this.
    def with_openers(path, status)
      first = @reasons.size
      yield
      return if path.start_with?("../") || @reasons[first..].any?(&:all)

      # The tests that read the file are added. What one of them read may be kept in memory (in a
      # constant, a cache) and used by tests that ran after it in the same process without
      # opening the file again. Those are not linked to the file, and are left out, unless the
      # project asks for them (`tests_after_readers: true`): then every test that ran after a
      # reader is added, which for a file read early in a run is most of the suite. Never for a
      # file whose lines the map follows: what stays in memory from it is code, and a test that
      # runs that code is linked to it already.
      onward = @after_readers && !@map.covered?(path)
      found = [@map.readers(path, onward:)]
      # Whether the file exists only changed if it was added, deleted or renamed.
      unless status == "M"
        # A test framework finds its test files by listing folders before any test runs. That is
        # how a new test file gets to run at all, and a new test file is run whole anyway, so
        # for test files those listings aren't a reason to run everything.
        discovery = @rules.classify(path).kind == :test
        found << @map.listers(path, moved_folders(path), onward:, boot: !discovery)
      end
      return if found.all?(&:none?)

      asked = if status == "M" || found.last.none? then "read it"
              else found.first.none? ? "looked for files like it" : "read it or looked for files like it"
              end
      if @rules.own_ignore?(path)
        return note(path, "recorded tests #{asked}, but your `ignore` line leaves them out", [])
      end
      return run_all(path, "something #{asked} while the app was starting, so any test may depend on it") if found.any?(&:all)

      files = found.flat_map(&:files).uniq.sort
      @files.merge(files)
      tests = files.reduce(found.map(&:tests).reduce(:|)) { |all, file| all | @map.tests_in_file(file) }
      note(path, "recorded tests #{asked}#{' (those, and the tests that ran after them)' if onward}", tests)
    end

    # The folders above a file that weren't there at the map's commit or aren't there now: they
    # appear or vanish with it, which answers a question such as `Dir["docs/*"]` too.
    def moved_folders(path)
      folders = []
      folders << File.dirname(folders.last || path) while (folders.last || path).include?("/")
      folders.reject { @folder_then.(_1) && @folder_now.(_1) }
    end

    # A file elsewhere in the repository, when the project is one folder of it. The map only
    # follows files inside the project's folder, so unless the file is one that can't affect tests
    # (docs, browser-only files, an `ignore` pattern such as "../frontend/**"), run everything.
    def outside(path, verdict, suffix = "")
      return note(path, verdict.reason, []) if %i[ignore browser].include?(verdict.kind)

      run_all(path, "outside this project's folder, where the map can't follow it#{suffix}")
    end

    # A file that had uncommitted edits when the map was made: the map saw those edits, not the
    # committed version, so compare nothing and take every test that ran it.
    def dirty_file(path)
      verdict = @rules.classify(path)
      if path.start_with?("../")
        return %i[ignore browser].include?(verdict.kind) ? nil : outside(path, verdict, " (uncommitted when the map was made)")
      end

      case verdict.kind
      when :ignore, :browser then nil
      when :global then run_all(path, "#{verdict.reason}, uncommitted when the map was made")
      when :test then test_file(path, "M")
      when :ruby
        # What the map saw isn't in git, so there is nothing to compare the file with: any part of
        # it may differ, the code that runs on loading included.
        if path.match?(Watch::UNFOLLOWED) then run_all(path, "uncommitted when the map was made")
        else load_time(path, "uncommitted when the map was made", "the map saw another version of it")
        end
      else
        if @map.covered?(path)
          note(path, "uncommitted when the map was made: every test that ran it", @map.tests_touching(path))
        else
          run_all(path, "uncommitted when the map was made")
        end
      end
    end

    def test_file(path, status)
      return note(path, "test file deleted", []) if status == "D"

      @files << path
      note(path, status == "A" ? "new test file (whole file)" : "test file changed (whole file)", @map.tests_in_file(path))
    end

    def ruby_file(path, status)
      return run_all(path, "loaded before Pitstop started recording, so no test is linked to it") if @map.unseen.include?(path)
      return run_all(path, "Ruby code in a folder the map doesn't follow") if path.match?(Watch::UNFOLLOWED)
      # Nothing was recorded about a file that didn't exist. It may be loaded with its whole folder,
      # found by its name, or reopen a class the tests already use.
      return run_all(path, "new Ruby file: it may be loaded by its name or its folder") if status == "A"
      return load_time(path, "file deleted", "any test may depend on what it defined") if status == "D"

      old = @old_source.(path)
      now = @new_source.(path)
      return load_time(path, "file changed", "its old or new version can't be read") if old.nil? || now.nil?

      UnitDiff.compare(old, now).each { unit_change(path, _1) }
    end

    def unit_change(path, change)
      case change.kind
      when :changed, :removed
        return load_time(path, "#{change.key} #{change.kind}", "a one-line or empty method, so calls to it can't be seen") if change.blind

        body = (change.old_lines.begin + 1)..change.old_lines.end
        return run_all(path, "#{change.key} runs while the app boots") if @map.ran_during_boot?(path, body)

        note(path, "#{change.key} #{change.kind}", @map.tests_touching(path, change.old_lines))
      when :added then added(path, change)
      when :skeleton then load_time(path, "code outside methods changed", "it runs when the file loads")
      when :unparsable then load_time(path, "doesn't parse (#{change.key})", "no test can load it")
      end
    end

    # A method that wasn't there before. The danger is one that takes the place of a method the
    # class already answered to (`def to_param` in a model, `def initialize` in a class that had
    # none): tests that relied on the old one needn't have run a line of this file, so everything
    # runs. But most added methods are helpers under a brand-new name, called from code changed
    # in the same commit. When no class or module had a method of that name, the name appears
    # nowhere in the project, and nothing lists this class's methods, no existing code could have
    # been calling it: only the tests that ran the file are picked, as for any change the map
    # can follow.
    def added(path, change)
      reason = not_new(change.unit)
      return load_time(path, "#{change.key} added", reason) if reason

      note(path, "#{change.key} added under a name nothing used before (every test that ran the file)", @map.tests_touching(path))
    end

    # Why an added unit can't be treated as a brand-new name, or nil if it can.
    def not_new(unit)
      return "it may replace a method the class already had" unless unit&.method

      marks = @map.module_marks(unit.owner)
      return "it may replace a method, and #{unit.owner} wasn't a class the recording knew" if marks.nil?
      return "a method of that name already existed, which it may replace" if @map.method?(unit.method)

      listing = unit.class_side ? "c" : "i"
      if marks.include?(unit.hidden ? listing.upcase : listing)
        return "code lists the methods of #{unit.owner} and can find it without naming it"
      end
      return "its name was already used in the project, by code that may now reach it" if @mentioned.(unit.method)

      nil
    end

    # A change to code that runs when its file loads: anything outside a method, a method being
    # defined, the whole file going. Most files load before the first test, so no test is linked
    # to that code, yet a test can depend on it without running a line of the file: a constant
    # read from another file, a `validates`, an inherited method that a new one now replaces.
    # Which tests those are isn't recorded, so every test runs. The one case that is certain: a
    # file nothing loaded while the map was recorded can't be changing what those tests do.
    def load_time(path, what, why)
      if loaded?(path)
        run_all(path, "#{what}: #{why}, so any test may depend on it")
      else
        note(path, "#{what}, in a file no recorded test loaded", [])
      end
    end

    # Every loaded file ran at least one line (its first statement), during a test or before them
    # all, unless it holds no code, in which case the map can't tell and it counts as loaded.
    def loaded?(path)
      return true if @map.covered?(path) || @map.boot.key?(path)

      old = @old_source.(path)
      !old.nil? && Units.parse(old).empty?
    end

    # Templates and other files Ruby's coverage can see (ERB is compiled to Ruby with its own path).
    # A template only runs when it is rendered, so the tests that rendered it are the ones it can
    # affect. A new one has no such tests, and Rails picks templates up by name (a layout named
    # after a controller, a second format of a page), so like any other new file it runs everything.
    def other_file(path, status, verdict)
      if @map.covered?(path)
        note(path, status == "D" ? "file deleted: every test that ran it" : "every test that ran this file", @map.tests_touching(path))
      elsif status == "A" && @rules.other_kind(path) == "template"
        run_all(path, "new template: it may be picked up by its name alone")
      else
        # Also when a test was seen reading it: who read a file narrows docs and browser files,
        # which are taken not to matter to anyone else. A data file may.
        run_all(path, verdict.reason.sub(" (not followed yet)", ", which any test may depend on"))
      end
    end

    def note(path, what, tests)
      @tests.merge(tests)
      @reasons << Reason.new(path:, what:, tests: tests.size, all: false)
    end

    def run_all(path, what)
      @run_all ||= "#{path}: #{what}"
      @reasons << Reason.new(path:, what:, tests: @map.tests.size, all: true)
    end
  end
end
