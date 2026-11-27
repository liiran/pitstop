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
      # Comments and blank lines change nothing.
      assert_equal [], try(shop) { shop.edit("lib/cart.rb", "  def total\n", "  # The sum.\n\n  def total\n") }

      # Everything below is code that runs when the file loads, before the tests, so no test is
      # linked to it and any test may depend on it: all of them run.
      # A one-line method: its line runs on loading, and a call to it adds nothing to tell apart.
      assert_equal :all, try(shop) { shop.edit("lib/cart.rb", 'def label = "cart"', 'def label = "basket"') }
      # Code outside methods (a constant).
      assert_equal :all, try(shop) { shop.edit("lib/cart.rb", "MAX = 3", "MAX = 4") }
      # A new method, which may replace one the class inherited.
      assert_equal :all, try(shop) { shop.edit("lib/cart.rb", "  def label", "  def to_s\n    label\n  end\n\n  def label") }
      # A file that doesn't parse any more.
      assert_equal :all, try(shop) { shop.edit("lib/cart.rb", "def total", "def total(") }
      # A new file: it may be loaded with its folder or found by its name.
      assert_equal :all, try(shop) { shop.write("lib/coupon.rb", "class Coupon\nend\n") }
    end
  end

  # A method added to a class. Under a name that was already a method somewhere, it may be taking
  # the place of one the tests relied on, and everything runs. Under a name no class had and no
  # file mentions, nothing could have been calling it: only the tests that ran the file run.
  def test_an_added_method_is_narrowed_only_under_a_name_nothing_used_before
    Shop.recorded do |shop|
      helper = "  def items_over(limit)\n    @items.select { _1 > limit }\n  end\n\n  def label"
      assert_equal %w[CartTest#test_full CartTest#test_label CartTest#test_total], try(shop) { shop.edit("lib/cart.rb", "  def label", helper) }
      code, out, = shop.pitstop("list") # nothing changed now
      assert_equal 0, code, out

      # `to_s` is a method every object already has.
      assert_equal :all, try(shop) { shop.edit("lib/cart.rb", "  def label", "  def to_s\n    label\n  end\n\n  def label") }
      # `format` is new to Cart, but Price has a method of that name.
      assert_equal :all, try(shop) { shop.edit("lib/cart.rb", "  def label", "  def format\n    label\n  end\n\n  def label") }

      shop.edit("lib/cart.rb", "  def label", helper)
      code, out, = shop.pitstop("list")
      assert_equal 0, code
      assert_match "lib/cart.rb  Cart#items_over added under a name nothing used before (every test that ran the file)  → 3 tests", out
    end
  end

  # The case the rule above exists for. A constant lives in a file of its own, and a method in
  # another file reads it. The test runs that method and never a line of the constant's file,
  # which loaded before the tests began. Changing the constant breaks the test.
  def test_a_constant_read_from_another_file
    cart = <<~RUBY
      require "limits"
      class Cart
        def initialize(items)
          @items = items
        end

        def full?
          @items.size >= Limits::MAX
        end
      end
    RUBY
    test = <<~RUBY
      require_relative "test_helper"
      require "cart"
      class CartTest < Minitest::Test
        def test_full
          assert Cart.new([1, 2, 3]).full?
          refute Cart.new([1, 2]).full?
        end
      end
    RUBY
    Fixture.project("lib/limits.rb" => "module Limits\n  MAX = 3\nend\n", "lib/cart.rb" => cart, "test/test_helper.rb" => Shop::HELPER,
                    "test/cart_test.rb" => test, "Rakefile" => Shop::RAKEFILE) do |shop|
      shop.commit
      code, out, err = shop.pitstop("record")
      assert_equal 0, code, out + err
      refute shop.map["files"].key?("lib/limits.rb"), "no test runs a line of the constant's file"

      shop.edit("lib/limits.rb", "MAX = 3", "MAX = 2") # now a cart of two is full
      code, out, err = run_tests(shop)
      assert_match "lib/limits.rb  code outside methods changed: it runs when the file loads, so any test may depend on it  → all tests", out
      assert_equal 1, code, "the broken test ran and failed:\n#{out}#{err}"
      assert_match "1 failures", out
    end
  end

  def test_deleted_and_renamed_files_and_committed_changes
    Shop.recorded do |shop|
      # What a file defined when it loaded goes with it; a renamed file is one gone and a new one.
      assert_equal :all, try(shop) { shop.delete("lib/price.rb") }
      assert_equal :all, try(shop) { shop.move("lib/cart.rb", "lib/basket.rb") }
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
      # A data file the map can't follow: everything, with the reason.
      shop.write("lib/rates.json", "{}")
      code, out, = shop.pitstop("list")
      assert_equal 0, code
      assert_match "lib/rates.json  .json file, which any test may depend on  → all tests", out
      shop.delete("lib/rates.json")

      # Docs and browser-only files: nothing.
      assert_equal [], try(shop) { shop.edit("README.md", "Shop", "The shop") }
      assert_equal [], try(shop) { shop.write("app/assets/stylesheets/cart.css", "a{}") }
      assert_equal [], try(shop) { shop.write("docs/guide.md", "hi") }
    end
  end

  # The map saw a version of the file that isn't in git, so there's nothing to compare it with:
  # any part of it may differ, the code that runs on loading included.
  def test_ruby_files_uncommitted_when_the_map_was_made_run_everything
    Fixture.project(Shop::FILES) do |shop|
      shop.commit("start")
      shop.edit("lib/cart.rb", "@items.sum", "@items.sum + 0")
      code, _, err = shop.pitstop("record")
      assert_equal 0, code, err
      assert_equal ["lib/cart.rb"], shop.map["dirty"]
      shop.git("checkout", "-q", "--", "lib/cart.rb") # back to the committed version
      assert_equal :all, picked(shop)
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
      assert_match ".pitstop.yml  Pitstop's settings  → all tests", out, "changing the rules themselves runs everything"

      shop.pitstop("record")
      shop.write("lib/rates.json", "{}")
      assert_equal [], picked(shop)

      shop.write(".pitstop.yml", "ignore: [lib/rates.json]\ncommand: ruby -e 'puts :custom_command'\n")
      code, out, = shop.pitstop("run")
      assert_equal 0, code
      assert_match "custom_command", out

      # A docs file that a test reads: `global` overrules the built-in rule that docs run nothing.
      shop.write(".pitstop.yml", "global: [README.md]\n")
      shop.commit("the readme is checked by a test")
      shop.pitstop("record")
      shop.edit("README.md", "Shop", "The shop")
      code, out, = shop.pitstop("list")
      assert_equal 0, code
      assert_match "README.md  app-wide file  → all tests", out
      shop.git("checkout", "-q", "README.md")

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

  def save_map(shop, data)
    FileUtils.mkdir_p(File.join(shop.dir, ".pitstop"))
    Zlib::GzipWriter.open(File.join(shop.dir, ".pitstop", "map.json.gz")) { _1.write(JSON.generate(data)) }
  end

  # For a CI job that may or may not find a map: one command that is right either way.
  def test_run_all_without_map_runs_every_test_when_there_is_no_map_to_use
    Fixture.project(Shop::FILES) do |shop|
      shop.commit("start")
      code, out, err = run_tests(shop, "--all-without-map")
      assert_equal 0, code, out + err
      assert_match "Pitstop: there is no map yet (`pitstop record` makes one), so running every test", out
      assert_equal 5, @ran, out
      refute File.exist?(File.join(shop.dir, ".pitstop")), "a run without a map records nothing"

      # A failing test is still a failing run.
      shop.edit("lib/price.rb", "cents / 100", "cents / 10")
      code, = run_tests(shop, "--all-without-map")
      assert_equal 1, code
      assert_equal 5, @ran
      shop.git("checkout", "-q", "--", "lib/price.rb")

      # A map this version of Pitstop can't read, as after an upgrade.
      save_map(shop, "version" => 1, "commit" => "0" * 40, "tests" => [])
      code, out, err = run_tests(shop, "--all-without-map", "--", Gem.ruby, "-S", "rake", "test")
      assert_equal 0, code, out + err
      assert_match "Pitstop: the map can't be used (.pitstop/map.json.gz is from another version of Pitstop), so running every test", out
      assert_equal 5, @ran

      # Without the flag, both stay errors and run nothing.
      code, out, err = run_tests(shop)
      assert_equal 1, code
      assert_match "is from another version of Pitstop: run `pitstop record` again", err
      assert_equal 0, @ran, out
      FileUtils.rm_rf(File.join(shop.dir, ".pitstop"))
      code, = run_tests(shop)
      assert_equal 64, code
      assert_equal 0, @ran

      # Something in the map's place that can't be opened.
      FileUtils.mkdir_p(File.join(shop.dir, ".pitstop", "map.json.gz"))
      code, out, err = run_tests(shop, "--all-without-map")
      assert_equal 0, code, out + err
      assert_match(/Pitstop: the map can't be used \(\.pitstop\/map\.json\.gz can't be read \(.+\)\), so running every test/, out)
      assert_equal 5, @ran
      code, _, err = shop.pitstop("list")
      assert_equal 1, code
      assert_equal 1, err.lines.size, "one plain line, not a stack trace:\n#{err}"
    end
  end

  def test_run_all_without_map_changes_nothing_when_the_map_is_usable
    Shop.recorded do |shop|
      shop.edit("lib/cart.rb", "@items.sum", "@items.sum(0)")
      code, out, err = run_tests(shop, "--all-without-map")
      assert_equal 0, code, out + err
      assert_match "Running 1 of 5 tests (20.0%)", out
      assert_equal 1, @ran

      # Only a missing or unusable map is forgiven: wrong settings still stop the run.
      shop.write(".pitstop.yml", "ignore: docs\n")
      code, out, err = run_tests(shop, "--all-without-map")
      assert_equal 64, code
      assert_match ".pitstop.yml: ignore should be a list of file patterns", err
      assert_equal 0, @ran, out
      FileUtils.rm_rf(File.join(shop.dir, ".pitstop"))
      code, out, = run_tests(shop, "--all-without-map")
      assert_equal 64, code
      assert_equal 0, @ran, out
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

  # Two test files can open the same test class (a class name copied from one file to the next).
  # Each test belongs to the file it's written in: that's the file handed to a command that takes
  # test files, such as `bin/rails test`, and the file whose change runs the test.
  def test_a_test_class_opened_in_two_test_files
    rails = <<~RUBY
      abort "only `test` here" unless ARGV.shift == "test"
      (ARGV.empty? ? Dir["test/*_test.rb"].sort : ARGV).each { require File.expand_path(_1) }
    RUBY
    test = ->(lib, body) { "require_relative 'test_helper'\nrequire '#{lib}'\nclass ShopTest < Minitest::Test\n  #{body}\nend\n" }
    Fixture.project(
      "lib/cart.rb" => Shop::CART, "lib/price.rb" => Shop::PRICE, "test/test_helper.rb" => Shop::HELPER, "bin/rails" => rails,
      "test/cart_test.rb" => test.("cart", "def test_total = assert_equal(3, Cart.new([1, 2]).total)"),
      "test/price_test.rb" => test.("price", "def test_format = assert_equal('$1.05', Price.format(105))")
    ) do |shop|
      shop.commit
      code, out, err = shop.pitstop("record")
      assert_equal 0, code, out + err
      assert_equal({ "ShopTest#test_total" => "test/cart_test.rb", "ShopTest#test_format" => "test/price_test.rb" },
                   shop.map["tests"].to_h { [_1[0], _1[1]] })

      # Only the second file's test ran this line, so only the second file is handed over.
      shop.edit("lib/price.rb", "cents / 100", "cents.div(100)")
      code, out, err = run_tests(shop)
      assert_equal 0, code, out + err
      assert_match "Pitstop: ran 1 of 1 selected tests", out
      assert_equal 1, @ran
      shop.git("checkout", "-q", "lib/price.rb")

      # The second file changes, and the command loads every test file: its own test runs.
      shop.edit("test/price_test.rb", "def test_format", "# the same test\n  def test_format")
      code, out, err = run_tests(shop, "--", Gem.ruby, "bin/rails", "test", "test/cart_test.rb", "test/price_test.rb")
      assert_equal 0, code, out + err
      assert_match "plus 1 from whole test files", out
      assert_equal 1, @ran
      assert_empty err
    end
  end

  # `bin/rails test` with no file names leaves test/system (browser tests) out. A changed file in
  # there is a test file, but naming it would run tests the whole suite doesn't run, in a job that
  # may have no browser. It runs only when the map shows the recorded command ran it.
  def test_a_changed_test_file_that_bin_rails_test_leaves_out_is_not_run
    rails = <<~RUBY
      abort "only `test` here" unless ARGV.shift == "test"
      (ARGV.empty? ? Dir["test/**/*_test.rb"].sort - Dir["test/system/**/*_test.rb"] : ARGV).each { require File.expand_path(_1) }
    RUBY
    browser_test = <<~RUBY
      require_relative "../test_helper"
      class CheckoutTest < Minitest::Test
        def test_checks_out = assert(ENV["BROWSER"], "there is no browser here")
      end
    RUBY
    Fixture.project("lib/cart.rb" => Shop::CART, "test/test_helper.rb" => Shop::HELPER, "test/cart_test.rb" => Shop::CART_TEST,
                    "bin/rails" => rails, "test/system/checkout_test.rb" => browser_test) do |shop|
      shop.commit
      code, out, err = shop.pitstop("record")
      assert_equal 0, code, out + err
      assert_equal %w[test/cart_test.rb], shop.map["tests"].map { _1[1] }.uniq, "the plain command doesn't run test/system"

      shop.edit("lib/cart.rb", "@items.sum", "@items.sum(0)")
      shop.edit("test/system/checkout_test.rb", "def test_checks_out", "# the same test\n  def test_checks_out")
      assert_equal [[], %w[test/system/checkout_test.rb]], shop.selection.values_at("files", "left_out")
      code, out, err = run_tests(shop)
      assert_equal 0, code, out + err
      assert_match "test/system/checkout_test.rb  left out: `bin/rails test` doesn't run this folder", out
      assert_match "Pitstop: ran 1 of 1 selected tests", out
      assert_equal 1, @ran
      refute_match "warning", err
      shop.git("checkout", "-q", "lib/cart.rb", "test/system/checkout_test.rb")

      # Recorded with a command that does run it: now it is one of the suite's test files.
      with_browser = { "BROWSER" => "1" }
      code, out, err = shop.pitstop("record", "--", Gem.ruby, "bin/rails", "test", "test/cart_test.rb", "test/system/checkout_test.rb", env: with_browser)
      assert_equal 0, code, out + err
      shop.edit("test/system/checkout_test.rb", "def test_checks_out", "# the same test\n  def test_checks_out")
      assert_equal [%w[test/system/checkout_test.rb], []], shop.selection.values_at("files", "left_out")
      code, out, err = shop.pitstop("run", env: with_browser)
      assert_equal 0, code, out + err
      assert_match "plus 1 from whole test files", out
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

  # --- files a test reads -------------------------------------------------------------------------

  # A project whose tests depend on files without running a line of them: one reads a doc and
  # keeps it, one counts the docs, one checks a script is there.
  DOCS_TEST = <<~RUBY
    require_relative "test_helper"
    class DocsTest < Minitest::Test
      i_suck_and_my_tests_are_order_dependent! # in name order, so "the tests after it" are known
      ROOT = File.expand_path("..", __dir__)

      def notes = $notes ||= File.read("\#{ROOT}/docs/notes.md")

      def test_a_before = assert(true)
      def test_b_reads_the_notes = assert_equal("notes\\n", notes)
      def test_c_uses_what_was_read = assert_equal("notes\\n", notes)
      def test_d_counts_the_docs = assert_equal(%w[guide.md notes.md old], Dir.children("\#{ROOT}/docs").sort)
      def test_e_finds_the_setup_script = assert(File.exist?("\#{ROOT}/bin/setup"))
    end
  RUBY

  def docs_project(extra = {})
    files = { "lib/cart.rb" => Shop::CART, "lib/price.rb" => Shop::PRICE, "test/test_helper.rb" => Shop::HELPER, "Rakefile" => Shop::RAKEFILE,
              "test/docs_test.rb" => DOCS_TEST, "docs/notes.md" => "notes\n", "docs/guide.md" => "guide\n", "docs/old/1.md" => "one\n",
              "bin/setup" => "#!/bin/sh\n" }
    Fixture.project(files.merge(extra)) do |shop|
      shop.commit
      code, out, err = shop.pitstop("record")
      assert_equal 0, code, out + err
      yield shop
    end
  end

  def docs_tests(*letters) = letters.map { |letter| DOCS_TEST[/def (test_#{letter}\w+)/, 1] }.map { "DocsTest##{_1}" }

  def test_a_doc_a_test_reads_runs_the_tests_that_read_it
    docs_project do |shop|
      shop.write("docs/guide.md", "a better guide\n")
      assert_empty picked(shop), "no test reads the guide"

      shop.write("docs/notes.md", "new notes\n")
      assert_equal docs_tests("b"), picked(shop)
      code, out, = run_tests(shop)
      assert_equal 1, code, out
      assert_match "1 failures", out
    end
  end

  # What the default leaves out, and the setting that closes it. test_c never opens the notes:
  # it uses what test_b read and kept, so nothing links it to the file, and it fails with the new
  # text too. With `tests_after_readers: true`, every test that ran after a reader runs: test_c,
  # and also test_d and test_e, which have nothing to do with the notes.
  def test_with_tests_after_readers_the_tests_that_ran_after_a_reader_run_too
    docs_project(".pitstop.yml" => "tests_after_readers: true\n") do |shop|
      shop.write("docs/notes.md", "new notes\n")
      assert_equal docs_tests("b", "c", "d", "e"), picked(shop)
      code, out, = run_tests(shop)
      assert_equal 1, code, out
      assert_match "2 failures", out
    end
  end

  def test_a_file_added_or_removed_runs_the_tests_that_listed_its_folder
    docs_project do |shop|
      shop.write("docs/more.md", "more\n")
      assert_equal docs_tests("d"), picked(shop)
      shop.delete("docs/more.md")

      shop.delete("docs/guide.md")
      assert_equal docs_tests("d"), picked(shop)
    end
  end

  # `Dir.children("docs")` doesn't look inside docs/old, so a second file there changes nothing
  # for it. The first file of a new folder does: the folder itself is a new entry in docs.
  def test_a_new_folder_counts_for_the_tests_that_listed_the_folder_above_it
    docs_project do |shop|
      shop.write("docs/old/2.md", "two\n")
      assert_empty picked(shop)

      shop.write("docs/new/1.md", "one\n")
      assert_equal docs_tests("d"), picked(shop)
    end
  end

  def test_a_file_a_test_only_checks_for_matters_when_it_is_removed
    docs_project do |shop|
      shop.write("bin/setup", "#!/bin/sh\necho hello\n")
      assert_empty picked(shop), "what the script says is nothing the test looked at"

      shop.delete("bin/setup")
      assert_equal docs_tests("e"), picked(shop)
    end
  end

  # One test per changelog entry, made while the test file loads. A new entry means a new test,
  # which only exists if that test file runs.
  def test_a_file_added_to_a_folder_a_test_file_lists_as_it_loads_runs_that_test_file
    entries = <<~RUBY
      require_relative "test_helper"
      class ChangelogTest < Minitest::Test
        Dir[File.expand_path("../changelog/*.md", __dir__)].each do |path|
          define_method("test_\#{File.basename(path, '.md')}") { assert File.read(path).start_with?("* ") }
        end
      end
    RUBY
    docs_project("test/changelog_test.rb" => entries, "changelog/fix_a.md" => "* Fixed a.\n") do |shop|
      shop.write("changelog/fix_b.md", "Fixed b, without the star.\n")
      assert_equal ["test/changelog_test.rb"], shop.selection["files"]
      code, out, = run_tests(shop)
      assert_equal 1, code, out
      assert_match "test_fix_b", out
    end
  end

  def test_a_file_read_while_the_tests_load_runs_everything
    helper = Shop::HELPER + "LIMITS = File.read(File.expand_path(\"../limits.txt\", __dir__))\n"
    docs_project("test/test_helper.rb" => helper, "limits.txt" => "3\n") do |shop|
      shop.write("limits.txt", "4\n")
      assert_equal :all, picked(shop)
    end
  end

  def test_your_own_ignore_line_wins_over_a_recorded_read
    docs_project(".pitstop.yml" => "ignore:\n  - docs/**\n") do |shop|
      shop.write("docs/notes.md", "new notes\n")
      assert_empty picked(shop)
      assert_match(/your `ignore` line/, shop.selection["reasons"].map { _1["what"] }.join("\n"))
    end
  end

  # The file is opened by a second Ruby process that the test starts.
  def test_a_file_read_by_a_program_the_test_starts_counts_for_that_test
    test = <<~RUBY
      require_relative "test_helper"
      class ReportTest < Minitest::Test
        def test_prints_the_notes
          out = IO.popen([Gem.ruby, "-e", "print File.read(ARGV[0])", File.expand_path("../docs/notes.md", __dir__)], &:read)
          assert_equal "notes\\n", out
        end
      end
    RUBY
    Fixture.project("lib/cart.rb" => Shop::CART, "lib/price.rb" => Shop::PRICE, "test/test_helper.rb" => Shop::HELPER, "Rakefile" => Shop::RAKEFILE,
                    "test/report_test.rb" => test, "docs/notes.md" => "notes\n") do |shop|
      shop.commit
      code, out, err = shop.pitstop("record")
      assert_equal 0, code, out + err
      shop.write("docs/notes.md", "new notes\n")
      assert_equal ["ReportTest#test_prints_the_notes"], picked(shop)
    end
  end

  # Paths as real projects write them: a doubled slash, and a pattern whose choices are whole
  # paths (Rails looks for fixtures with "{/app/test/fixtures/}/users{.yml,/**/*.yml}").
  def test_untidy_paths_and_patterns_with_choices_are_understood
    test = <<~RUBY
      require_relative "test_helper"
      class LooksTest < Minitest::Test
        i_suck_and_my_tests_are_order_dependent!
        ROOT = File.expand_path("..", __dir__)

        def test_a_before = assert(true)
        def test_b_checks_with_two_slashes = assert(File.exist?("\#{ROOT}/docs//notes.md"))
        def test_c_lists_with_choices = assert_equal(1, Dir["{\#{ROOT}/docs/}/guide{.md,/**/*.md}"].size)
      end
    RUBY
    docs_project("test/docs_test.rb" => test) do |shop|
      shop.delete("docs/notes.md")
      assert_equal %w[LooksTest#test_b_checks_with_two_slashes], picked(shop)
      shop.write("docs/notes.md", "notes\n")

      shop.write("docs/guide/more.md", "more\n")
      assert_equal %w[LooksTest#test_c_lists_with_choices], picked(shop)
    end
  end
end
