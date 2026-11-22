require "set"
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

    def initialize(map:, changes:, old_source:, new_source:, rules: Rules.new)
      @map = map
      @changes = changes
      @old_source = old_source # ->(path) { content at the map's commit, or nil }
      @new_source = new_source # ->(path) { content now, or nil }
      @rules = rules
    end

    def select
      @tests = Set.new
      @files = Set.new
      @reasons = []
      @run_all = nil

      @changes.each { consider(_1) }
      @map.dirty.each { dirty_file(_1) }
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
      else
        if @map.covered?(path) || verdict.kind == :ruby
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
      return note(path, "file deleted: every test that ran it", @map.tests_touching(path)) if status == "D"
      return note(path, "new file, not run by any recorded test", []) if status == "A"

      old = @old_source.(path)
      now = @new_source.(path)
      return note(path, "file changed: every test that ran it", @map.tests_touching(path)) if old.nil? || now.nil?

      UnitDiff.compare(old, now).each { unit_change(path, _1) }
    end

    def unit_change(path, change)
      case change.kind
      when :changed, :removed
        body = change.single_line ? nil : (change.old_lines.begin + 1)..(change.old_lines.end - 1)
        if body && body.size.positive? && @map.ran_during_boot?(path, body)
          return run_all(path, "#{change.key} runs while the app boots")
        end

        tests = @map.tests_touching(path, change.old_lines)
        if tests.empty? && change.single_line
          # Ruby's line coverage doesn't see calls to one-line methods like `def x = 1`.
          return note(path, "#{change.key} #{change.kind} (one-liner: every test that ran the file)", @map.tests_touching(path))
        end

        note(path, "#{change.key} #{change.kind}", tests)
      when :added then note(path, "#{change.key} added (every test that ran the file)", @map.tests_touching(path))
      when :skeleton then note(path, "code outside methods changed (every test that ran the file)", @map.tests_touching(path))
      when :unparsable then note(path, "doesn't parse (#{change.key}): every test that ran the file", @map.tests_touching(path))
      end
    end

    # Templates and other files Ruby's coverage can see (ERB is compiled to Ruby with its own path).
    # A new template is only rendered once some code names it, and that code change is picked up
    # on its own; any other new file (data, settings) may be read by a glob, so it runs everything.
    def other_file(path, status, verdict)
      if @map.covered?(path)
        note(path, status == "D" ? "file deleted: every test that ran it" : "every test that ran this file", @map.tests_touching(path))
      elsif status == "A" && @rules.other_kind(path) == "template"
        note(path, "new template, not rendered by any recorded test", [])
      else
        run_all(path, verdict.reason.sub(" (not followed yet)", ", not seen by any recorded test"))
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
