require "minitest/autorun"
require_relative "../support/project"
require_relative "../support/shop"

# End to end: a real project in a real git repo, recorded once with `pitstop record`, then
# changed in every way the selection rules cover, checked through `pitstop list` and `pitstop run`.
class CLITest < Minitest::Test
  ALL = %w[CartTest#test_full CartTest#test_label CartTest#test_total PriceTest#test_format ReceiptTest#test_prints_a_price].freeze

  def picked(shop) = shop.selection.then { _1["run_all"] ? :all : _1["tests"].sort }

  # A fresh recording per test is slow (a second or so), so each test checks several changes
  # against one recording, undoing each change before the next.
  def try(shop)
    yield
    picked(shop)
  ensure
    shop.git("reset", "-q", "--hard")
    shop.git("clean", "-q", "-fd", "--exclude=.pitstop")
  end

  def test_record_maps_every_test_and_links_a_subprocess_to_its_test
    Shop.recorded do |shop, out, err|
      assert_match(/mapped 5 tests over 2 files/, out)
      assert_empty err.lines.grep(/pitstop: warning/), err
      map = shop.map
      assert_equal ALL, map["tests"].map(&:first).sort
      assert_equal shop.git("rev-parse", "HEAD").strip, map["commit"]
      receipt = map["tests"].index { _1.first == "ReceiptTest#test_prints_a_price" }
      assert map["files"]["lib/price.rb"].any? { |_, idx| idx.include?(receipt) }, "the subprocess's lines belong to its test"
      refute Dir.exist?(File.join(shop.dir, ".pitstop", "runs", "x")), "per-process files are cleaned up"
      assert_empty Dir[File.join(shop.dir, ".pitstop", "runs", "*")]
    end
  end

  def test_ruby_changes_pick_the_tests_that_ran_the_changed_code
    Shop.recorded do |shop|
      # A method body: only the tests that ran it (including the one that ran it in a subprocess).
      assert_equal %w[PriceTest#test_format ReceiptTest#test_prints_a_price],
                   try(shop) { shop.edit("lib/price.rb", "cents / 100", "cents.div(100)") }
      assert_equal ["CartTest#test_total"], try(shop) { shop.edit("lib/cart.rb", "@items.sum", "@items.sum(0)") }
      # A one-line method Ruby's coverage can't see being called: every test that ran the file.
      assert_equal %w[CartTest#test_full CartTest#test_label CartTest#test_total],
                   try(shop) { shop.edit("lib/cart.rb", 'def label = "cart"', 'def label = "basket"') }
      # Code outside methods (a constant): every test that ran the file.
      assert_equal %w[CartTest#test_full CartTest#test_label CartTest#test_total],
                   try(shop) { shop.edit("lib/cart.rb", "MAX = 3", "MAX = 4") }
      # A new method might override one used anywhere in the file's class.
      assert_equal %w[CartTest#test_full CartTest#test_label CartTest#test_total],
                   try(shop) { shop.edit("lib/cart.rb", "  def label", "  def empty? = @items.empty?\n\n  def label") }
      # Comments and blank lines change nothing.
      assert_equal [], try(shop) { shop.edit("lib/cart.rb", "  def total\n", "  # The sum.\n\n  def total\n") }
      # A file that doesn't parse any more: every test that ran it.
      assert_equal %w[CartTest#test_full CartTest#test_label CartTest#test_total],
                   try(shop) { shop.edit("lib/cart.rb", "def total", "def total(") }
      # A new file no recorded test loaded can't break one (a test that loads it changes too).
      assert_equal [], try(shop) { shop.write("lib/coupon.rb", "class Coupon\nend\n") }
    end
  end

  def test_deleted_and_renamed_files_and_committed_changes
    Shop.recorded do |shop|
      assert_equal %w[PriceTest#test_format ReceiptTest#test_prints_a_price], try(shop) { shop.delete("lib/price.rb") }
      assert_equal %w[CartTest#test_full CartTest#test_label CartTest#test_total],
                   try(shop) { shop.move("lib/cart.rb", "lib/basket.rb") }
      # Changes count the same committed or not: the diff is from the map's commit.
      shop.edit("lib/cart.rb", "@items.size >= MAX", "@items.size > MAX")
      shop.commit("off by one")
      assert_equal ["CartTest#test_full"], picked(shop)
    end
  end

  def test_test_files_run_whole_and_app_wide_files_run_everything
    Shop.recorded do |shop|
      changed = try(shop) { shop.edit("test/cart_test.rb", "[1, 2]).total", "[2, 1]).total") }
      assert_equal %w[CartTest#test_full CartTest#test_label CartTest#test_total], changed
      code, out, = shop.pitstop("list")
      assert_equal 0, code
      assert_match "Would run 0 of 5 tests", out, "nothing changed now"

      shop.write("test/coupon_test.rb", "require_relative 'test_helper'\nclass CouponTest < Minitest::Test\n  def test_x = assert(true)\nend\n")
      assert_equal ["test/coupon_test.rb"], shop.selection["files"], "a new test file runs whole"
      shop.delete("test/coupon_test.rb")

      %w[Rakefile test/test_helper.rb Gemfile config/settings.rb .ruby-version].each do |path|
        assert_equal :all, try(shop) { shop.write(path, "# changed\n") }, path
      end
      # A file the map can't follow and no test was seen reading: everything, with the reason.
      shop.write("lib/rates.json", "{}")
      code, out, = shop.pitstop("list")
      assert_equal 0, code
      assert_match "lib/rates.json  .json file, not seen by any recorded test  → all tests", out
      shop.delete("lib/rates.json")

      # Docs and browser-only files: nothing.
      assert_equal [], try(shop) { shop.edit("README.md", "Shop", "The shop") }
      assert_equal [], try(shop) { shop.write("app/assets/stylesheets/cart.css", "a{}") }
      assert_equal [], try(shop) { shop.write("docs/guide.md", "hi") }
    end
  end

  def test_files_uncommitted_when_the_map_was_made_take_every_test_that_ran_them
    Fixture.project(Shop::FILES) do |shop|
      shop.commit("start")
      shop.edit("lib/cart.rb", "@items.sum", "@items.sum + 0")
      code, _, err = shop.pitstop("record")
      assert_equal 0, code, err
      assert_equal ["lib/cart.rb"], shop.map["dirty"]
      shop.git("checkout", "-q", "--", "lib/cart.rb") # back to the committed version
      assert_equal %w[CartTest#test_full CartTest#test_label CartTest#test_total], picked(shop)
    end
  end

  def test_tests_that_failed_or_were_skipped_when_recorded_always_run
    files = Shop::FILES.merge("test/flaky_test.rb" => <<~RUBY)
      require_relative "test_helper"
      class FlakyTest < Minitest::Test
        def test_flaky = assert(ENV["FLAKY_PASS"])
        def test_later = skip("later")
      end
    RUBY
    Fixture.project(files) do |shop|
      shop.commit("start")
      code, out, = shop.pitstop("record")
      assert_equal 1, code, "the suite failed"
      assert_match "(2 didn't pass; they'll always run)", out
      assert_equal %w[FlakyTest#test_flaky FlakyTest#test_later], picked(shop)
    end
  end

  def test_explain_and_json
    Shop.recorded do |shop|
      shop.edit("lib/price.rb", "cents / 100", "cents.div(100)")
      shop.edit("README.md", "Shop", "The shop")
      code, out, = shop.pitstop("list", "--explain")
      assert_equal 0, code
      assert_match(/lib\/price\.rb\s+Price\.format changed  → 2 tests/, out)
      assert_match(/README\.md\s+docs or project metadata  → 0 tests/, out)
      assert_match "Would run 2 of 5 tests (40.0%)", out
      assert_match "    PriceTest#test_format  test/price_test.rb:5", out

      json = shop.selection
      assert_nil json["run_all"]
      assert_equal shop.map["commit"], json["map_commit"]
      assert_equal({ "path" => "lib/price.rb", "what" => "Price.format changed", "tests" => 2, "all" => false },
                   json["reasons"].find { _1["path"] == "lib/price.rb" })
    end
  end

  def test_a_map_from_a_commit_this_repo_does_not_have_runs_everything
    Shop.recorded do |shop|
      map = shop.map.merge("commit" => "f" * 40)
      Zlib::GzipWriter.open(File.join(shop.dir, ".pitstop", "map.json.gz")) { _1.write(JSON.generate(map)) }
      code, out, = shop.pitstop("list")
      assert_equal 0, code
      assert_match "Would run all 5 tests: the map's commit fffffff isn't in this repo", out
    end
  end

  def test_pitstop_yml_adds_rules_and_sets_the_command
    Shop.recorded do |shop|
      shop.write(".pitstop.yml", "ignore:\n  - lib/rates.json\n")
      shop.commit("config")
      code, out, = shop.pitstop("list", "--explain")
      assert_match ".pitstop.yml  app-wide file  → all tests", out, "changing the rules themselves runs everything"

      shop.pitstop("record")
      shop.write("lib/rates.json", "{}")
      assert_equal [], picked(shop)

      shop.write(".pitstop.yml", "ignore: [lib/rates.json]\ncommand: ruby -e 'puts :custom_command'\n")
      code, out, = shop.pitstop("run")
      assert_equal 0, code
      assert_match "custom_command", out

      shop.write(".pitstop.yml", "ignored: [x]\n")
      code, _, err = shop.pitstop("list")
      assert_equal 64, code
      assert_match '.pitstop.yml: unknown setting "ignored"', err
      shop.write(".pitstop.yml", "ignore: lib/x.rb\n")
      code, _, err = shop.pitstop("list")
      assert_equal 64, code
      assert_match ".pitstop.yml: ignore should be a list of file patterns", err
    end
  end

  def test_usage_errors
    Fixture.project(Shop::FILES) do |shop|
      shop.commit
      code, _, err = shop.pitstop("list")
      assert_equal 64, code
      assert_match "no map yet: run `pitstop record` first", err
      assert_equal 64, shop.pitstop("frobnicate").first
      assert_equal 64, shop.pitstop("list", "--nope").first
      assert_equal 0, shop.pitstop("--help").first
    end
    Dir.mktmpdir do |dir|
      _, err, status = Open3.capture3(Fixture::CLEAN_ENV, Gem.ruby, Fixture::EXE, "record", chdir: dir)
      assert_equal 1, status.exitstatus
      assert_match "git rev-parse failed", err
    end
  end

  # --- pitstop run -------------------------------------------------------------------------------

  def run_tests(shop, *argv)
    code, out, err = shop.pitstop("run", *argv)
    @ran = out.scan(/^(\d+) runs?, /).flatten.map(&:to_i).sum
    [code, out, err]
  end

  def test_run_runs_only_the_selected_tests_and_checks_they_all_ran
    Shop.recorded do |shop|
      shop.edit("lib/cart.rb", "@items.sum", "@items.sum(0)")
      code, out, err = run_tests(shop)
      assert_equal 0, code, out + err
      assert_match "Running 1 of 5 tests (20.0%)", out
      assert_equal 1, @ran, "Minitest itself reports one test run:\n#{out}"
      assert_match "Pitstop: ran 1 of 1 selected tests", out
      refute Dir.exist?(File.join(shop.dir, ".pitstop", "ran-x"))
      assert_empty Dir[File.join(shop.dir, ".pitstop", "ran-*")], "the run's files are cleaned up"
    end
  end

  def test_run_reports_a_failing_selection_as_a_failure
    Shop.recorded do |shop|
      shop.edit("lib/price.rb", "cents / 100", "cents / 10")
      code, out, = run_tests(shop)
      assert_equal 1, code
      assert_equal 2, @ran
      assert_match "2 failures", out
      assert_match "Pitstop: ran 2 of 2 selected tests", out
    end
  end

  def test_run_runs_new_and_changed_test_files_whole
    Shop.recorded do |shop|
      shop.write("test/coupon_test.rb", "require_relative 'test_helper'\nclass CouponTest < Minitest::Test\n  def test_a = assert(true)\n  def test_b = assert(true)\nend\n")
      shop.edit("lib/price.rb", "cents / 100", "cents.div(100)")
      code, out, err = run_tests(shop)
      assert_equal 0, code, out + err
      assert_match "Running 2 of 5 tests (40.0%), plus 1 whole test file: test/coupon_test.rb", out
      assert_equal 4, @ran
      assert_match "Pitstop: ran 2 of 2 selected tests, plus 2 from whole test files", out
    end
  end

  def test_run_with_nothing_to_run_or_everything_to_run
    Shop.recorded do |shop|
      shop.edit("README.md", "Shop", "The shop")
      code, out, = run_tests(shop)
      assert_equal 0, code
      assert_match "Nothing to run: none of your changes can affect a test.", out
      assert_equal 0, @ran

      shop.write("Gemfile.lock", "changed")
      code, out, = run_tests(shop, "--", Gem.ruby, "-S", "rake", "test")
      assert_equal 0, code, out
      assert_match "Running all 5 tests: Gemfile.lock: app-wide file", out
      assert_equal 5, @ran
    end
  end

  # The check that matters most: a run that quietly ran fewer tests than it selected must fail.
  def test_run_fails_when_selected_tests_did_not_run
    Shop.recorded do |shop|
      shop.edit("lib/price.rb", "cents / 100", "cents.div(100)")
      code, out, err = run_tests(shop, "--", Gem.ruby, "-Itest", "test/price_test.rb")
      assert_equal 3, code, out + err
      assert_match "Pitstop: ran 1 of 2 selected tests", out
      assert_match "pitstop: 1 selected test didn't run, so this run doesn't cover your change: ReceiptTest#test_prints_a_price", err

      code, _, err = run_tests(shop, "--", Gem.ruby, "-e", "exit 0")
      assert_equal 3, code
      assert_match "pitstop: no tests ran at all", err
    end
  end

  # A command Pitstop can't hand a file list to still runs only the selected tests: the filter
  # drops the others as their files load.
  def test_run_filters_any_minitest_command
    Shop.recorded do |shop|
      shop.write("test/all.rb", "Dir[File.join(__dir__, '*_test.rb')].sort.each { require _1 }\n")
      shop.commit("runner")
      shop.pitstop("record", "--", Gem.ruby, "-Itest", "test/all.rb")
      shop.edit("lib/cart.rb", "@items.size >= MAX", "@items.size > MAX")
      code, out, err = run_tests(shop, "--", Gem.ruby, "-Itest", "test/all.rb")
      assert_equal 1, code, out + err
      assert_equal 1, @ran, out
      assert_match "CartTest#test_full", out, "the change broke it and the one selected test caught it"
      assert_match "Pitstop: ran 1 of 1 selected tests", out
    end
  end

  # A test of a test helper builds a test class and runs it inside itself. The inner test isn't
  # one Minitest schedules: it's part of the outer test, when recording and when running.
  def test_a_test_run_inside_another_test_belongs_to_it
    nested = <<~RUBY
      require_relative "test_helper"
      require "cart"

      class HelperTest < Minitest::Test
        def test_a_test_built_inside_a_test_passes
          inner = Class.new(Minitest::Test) do
            define_method(:test_full) { assert Cart.new([1, 2, 3]).full? }
          end
          Minitest::Runnable.runnables.delete(inner)
          results = inner.runnable_methods.map { inner.new(_1).run }
          assert_equal 1, results.size
          assert results.all?(&:passed?), "the inner test failed"
        end
      end
    RUBY
    Fixture.project(Shop::FILES.merge("test/helper_test.rb" => nested)) do |shop|
      shop.commit("start")
      code, out, err = shop.pitstop("record")
      assert_equal 0, code, out + err
      assert_match "mapped 6 tests", out
      assert_empty err
      shop.edit("lib/cart.rb", "@items.size >= MAX", "MAX <= @items.size")
      assert_equal %w[CartTest#test_full HelperTest#test_a_test_built_inside_a_test_passes], picked(shop)

      code, out, err = run_tests(shop)
      assert_equal 0, code, out + err
      assert_equal 2, @ran
      assert_match "Pitstop: ran 2 of 2 selected tests", out

      shop.edit("lib/cart.rb", "MAX <= @items.size", "MAX < @items.size")
      code, out, = run_tests(shop)
      assert_equal 1, code
      assert_match "the inner test failed", out
      assert_match "Pitstop: ran 2 of 2 selected tests", out
    end
  end

  # A test that runs a test suite in a separate Ruby process (a test of a test tool): that suite
  # is part of the test, so the filter, which the process inherits, must leave it whole.
  def test_a_suite_a_test_runs_in_a_subprocess_runs_whole
    files = Shop::FILES.merge(
      "test/inner/cart_check.rb" => <<~RUBY,
        require_relative "../test_helper"
        require "cart"

        class CartCheck < Minitest::Test
          def test_full = assert(Cart.new([1, 2, 3]).full?)
        end
      RUBY
      "test/suite_test.rb" => <<~RUBY
        require_relative "test_helper"
        require "open3"

        class SuiteTest < Minitest::Test
          def test_runs_a_suite
            out, status = Open3.capture2e(Gem.ruby, File.expand_path("inner/cart_check.rb", __dir__))
            assert status.success?, out
            assert_match "1 runs, 1 assertions, 0 failures", out
          end
        end
      RUBY
    )
    Fixture.project(files) do |shop|
      shop.commit("start")
      code, out, err = shop.pitstop("record")
      assert_equal 0, code, out + err
      shop.edit("lib/cart.rb", "@items.size >= MAX", "MAX <= @items.size")
      assert_equal %w[CartTest#test_full SuiteTest#test_runs_a_suite], picked(shop)

      code, out, err = run_tests(shop)
      assert_equal 0, code, out + err
      assert_match "Pitstop: ran 2 of 2 selected tests\n", out
    end
  end

  def test_minitest_6_end_to_end
    version = Fixture.latest("minitest", 6)
    skip "Minitest 6 not installed" unless version
    Shop.recorded(env: { "MT_VERSION" => version }) do |shop, out|
      assert_match "mapped 5 tests", out
      shop.edit("lib/cart.rb", "@items.sum", "@items.sum(0)")
      code, out, err = shop.pitstop("run", env: { "MT_VERSION" => version })
      assert_equal 0, code, out + err
      assert_match "Pitstop: ran 1 of 1 selected tests", out
      assert_match "1 runs", out
    end
  end

  # --- RSpec -----------------------------------------------------------------------------------

  RSPEC = {
    "bin/rspec" => Fixture::RSPEC_BIN,
    "lib/stock.rb" => <<~RUBY,
      class Stock
        def initialize(items) = @items = items

        def count
          @items.size
        end

        def empty?
          @items.empty?
        end
      end
    RUBY
    "spec/stock_spec.rb" => <<~RUBY,
      require_relative "../lib/stock"
      RSpec.describe Stock do
        it("counts") { expect(Stock.new([1, 2]).count).to eq 2 }
        it("knows when it's empty") { expect(Stock.new([]).empty?).to be true }
        context "with one item" do
          it("is not empty") { expect(Stock.new([1]).empty?).to be false }
        end
      end
    RUBY
    "spec/other_spec.rb" => <<~RUBY,
      RSpec.describe "other" do
        it("adds") { expect(1 + 1).to eq 2 }
      end
    RUBY
    # Two ways an example ends without returning through the around hooks normally.
    "spec/aggregate_spec.rb" => <<~RUBY,
      require_relative "../lib/stock"
      RSpec.describe "aggregated", :aggregate_failures do
        it("checks twice") { s = Stock.new([]); expect(s.empty?).to be true; expect(s.count).to eq 0 }
      end
    RUBY
    "spec/setup_spec.rb" => <<~RUBY
      require_relative "../lib/stock"
      RSpec.describe "set up once" do
        before(:all) { raise "not empty" unless Stock.new([]).empty? }
        it("works") { expect(1).to eq 1 }
      end
    RUBY
  }.freeze

  EMPTY = %w[./spec/aggregate_spec.rb[1:1] ./spec/setup_spec.rb[1:1] ./spec/stock_spec.rb[1:2] ./spec/stock_spec.rb[1:3:1]].freeze

  def test_rspec_end_to_end
    skip "rspec not installed" unless Fixture.rspec?
    Fixture.project(RSPEC.merge(".pitstop.yml" => "command: ruby bin/rspec\n")) do |shop|
      shop.commit("start")
      code, out, err = shop.pitstop("record")
      assert_equal 0, code, out + err
      assert_match "mapped 6 tests", out
      assert_empty err.lines.grep(/warning/), err

      shop.edit("lib/stock.rb", "@items.empty?", "@items.none?")
      assert_equal EMPTY, picked(shop), "before(:all) code belongs to every example in its file"
      code, out, err = shop.pitstop("run")
      assert_equal 0, code, out + err
      assert_match "4 examples, 0 failures", out
      assert_match "Pitstop: ran 4 of 4 selected tests", out

      shop.write("spec/new_spec.rb", "RSpec.describe('new') { it('works') { expect(1).to eq 1 } }\n")
      code, out, err = shop.pitstop("run")
      assert_equal 0, code, out + err
      assert_match "5 examples, 0 failures", out
      assert_match "Pitstop: ran 4 of 4 selected tests, plus 1 from whole test files", out
    end
  end

  # Examples that fail without returning normally (an aggregated failure, or an error in their
  # group's before(:all)) still ran: the check counts them, and the run reports the failure.
  def test_rspec_failures_that_skip_the_around_hooks_still_count_as_run
    skip "rspec not installed" unless Fixture.rspec?
    Fixture.project(RSPEC.merge(".pitstop.yml" => "command: ruby bin/rspec\n")) do |shop|
      shop.commit("start")
      shop.pitstop("record")
      shop.edit("lib/stock.rb", "@items.empty?", "!@items.empty?")
      code, out, err = shop.pitstop("run")
      assert_equal 1, code, out + err
      assert_match "4 examples, 4 failures", out
      assert_match "Pitstop: ran 4 of 4 selected tests", out
      refute_match "didn't run", err
    end
  end
end
