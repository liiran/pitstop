require "minitest/autorun"
require_relative "../support/project"
require "pitstop/map"

# Runs tiny projects' tests with the recorder loaded the way `pitstop record` loads it, and checks
# what each test (or test file) was said to run.
class RecordTest < Minitest::Test
  CART = <<~RUBY
    class Cart
      def initialize(items)
        @items = items
      end

      def total
        @items.sum
      end

      def full?
        @items.size >= 3
      end
    end
  RUBY

  MINITEST = {
    "lib/cart.rb" => CART,
    "test/helper.rb" => <<~RUBY,
      gem "minitest", ENV["MT_VERSION"] if ENV["MT_VERSION"]
      require "minitest/autorun"
      require_relative "../lib/cart"
    RUBY
    "test/total_test.rb" => <<~RUBY,
      require_relative "helper"
      class TotalTest < Minitest::Test
        def test_total = assert_equal(3, Cart.new([1, 2]).total)
        def test_total_empty = assert_equal(0, Cart.new([]).total)
      end
    RUBY
    "test/full_test.rb" => <<~RUBY,
      require_relative "helper"
      class FullTest < Minitest::Test
        def test_full = assert(Cart.new([1, 2, 3]).full?)
        def test_not_full = refute(Cart.new([1]).full?)
      end
    RUBY
    "test/all.rb" => <<~RUBY
      Dir[File.join(__dir__, "*_test.rb")].sort.each { require _1 }
    RUBY
  }.freeze

  def minitest_project(extra = {}, &) = Fixture.project(MINITEST.merge(extra), &)

  # Runs `command` in the project with the recorder loaded; returns every record written.
  def record(dir, command, env: {}, expect_success: true)
    @runs = (@runs || 0) + 1
    out = File.join(dir, ".pitstop", "runs", @runs.to_s)
    env = Fixture::CLEAN_ENV.merge("RUBYOPT" => "-I#{Fixture::LIB} -rpitstop/record", "PITSTOP_OUT" => out,
                                   "PITSTOP_ROOT" => dir).merge(env)
    output, status = Open3.capture2e(env, Gem.ruby, *command, chdir: dir)
    assert status.success?, output if expect_success
    @output = output
    @out = out
    Dir["#{out}/*.jsonl"].flat_map { |f| File.readlines(f).map { JSON.parse(_1) } }
  end

  def map(commit: "abc") = Pitstop::Map.build(@out, commit:)

  def lines(ranges) = ranges.flat_map { |a, b| (a..b).to_a }

  def tests_by_id(records) = records.select { _1["kind"] == "test" }.to_h { [_1["id"], _1] }

  def test_each_test_gets_only_the_lines_it_ran_under_every_minitest
    skip "no Minitest installed for the matrix" if Fixture.minitest_versions.empty?
    minitest_project do |p|
      Fixture.minitest_versions.each do |version|
        records = record(p.dir, ["test/all.rb", "--seed", "1"], env: { "MT_VERSION" => version })
        tests = tests_by_id(records)
        assert_equal [7], lines(tests["TotalTest#test_total"]["cov"]["lib/cart.rb"]) - [3], "Minitest #{version}"
        assert_equal [11], lines(tests["FullTest#test_full"]["cov"]["lib/cart.rb"]) - [3], "Minitest #{version}"
        assert_equal "test/total_test.rb", tests["TotalTest#test_total"]["file"]
        assert_equal 3, tests["TotalTest#test_total"]["line"]
        refute tests.values.any? { _1["cov"].key?("test/total_test.rb") }, "test files themselves aren't recorded"
        boot = records.find { _1["kind"] == "boot" }
        assert_includes lines(boot["cov"]["lib/cart.rb"]), 6, "method definitions run at boot"
        assert_equal [{ "kind" => "summary", "framework" => "minitest", "ran" => 4 }],
                     records.select { _1["kind"] == "summary" }.map { _1.except("pid") }
        assert_empty map.warnings, "Minitest #{version}"
      end
    end
  end

  def test_failed_and_skipped_tests_are_marked
    minitest_project("test/odd_test.rb" => <<~RUBY) do |p|
      require_relative "helper"
      class OddTest < Minitest::Test
        def test_fails = assert_equal(1, Cart.new([2]).total)
        def test_skips = skip("later")
        def test_errors = Cart.new(nil).total
      end
    RUBY
      tests = tests_by_id(record(p.dir, ["test/all.rb"], expect_success: false))
      assert_equal %w[fail skip fail], %w[test_fails test_skips test_errors].map { tests["OddTest##{_1}"]["status"] }
      assert_equal "pass", tests["TotalTest#test_total"]["status"]
    end
  end

  # Whatever order the files run in, a file's lines never leak into the file that ran before it.
  def test_per_file_recording_keeps_files_apart_in_any_order
    minitest_project do |p|
      [1, 2, 3, 4].each do |seed|
        records = record(p.dir, ["test/all.rb", "--seed", seed.to_s], env: { "PITSTOP_GRANULARITY" => "file" })
        groups = records.select { _1["kind"] == "group" }.to_h { [_1["file"], _1] }
        total = lines(groups.fetch("test/total_test.rb")["cov"]["lib/cart.rb"])
        full = lines(groups.fetch("test/full_test.rb")["cov"]["lib/cart.rb"])
        assert_includes total, 7
        refute_includes total, 11, "seed #{seed}: FullTest's lines leaked into TotalTest's file"
        assert_includes full, 11
        refute_includes full, 7, "seed #{seed}: TotalTest's lines leaked into FullTest's file"
        assert_equal %w[TotalTest#test_total TotalTest#test_total_empty], groups["test/total_test.rb"]["tests"].sort
        assert_equal %w[TotalTest#test_total TotalTest#test_total_empty], map.tests_touching("lib/cart.rb", 7..7).map { map.tests[_1].id }.sort
      end
    end
  end

  # By default a process starts per test and switches to per file once reading coverage costs
  # more than half the tests' own time: tiny tests switch, slower tests don't.
  def test_auto_granularity_switches_only_when_reading_coverage_dominates
    many = ->(body) { "require_relative 'helper'\nclass ManyTest < Minitest::Test\n  250.times { |i| define_method(\"test_\#{i}\") { #{body} } }\nend\n" }
    minitest_project("test/many_test.rb" => many.("assert Cart.new([i]).total")) do |p|
      records = record(p.dir, ["test/all.rb"])
      switched = records.find { _1["kind"] == "switched" }
      refute_nil switched, "250 tiny tests should switch to per file"
      assert_equal 100, switched["after"]
      assert records.any? { _1["kind"] == "group" && _1["file"] == "test/many_test.rb" }
      ids = map.tests_touching("lib/cart.rb", 7..7).map { map.tests[_1].id }
      assert_equal 250, ids.count { _1.start_with?("ManyTest#") }, "every tiny test is still linked to the line it ran"
    end
    minitest_project("test/many_test.rb" => many.("sleep 0.002; assert Cart.new([i]).total")) do |p|
      records = record(p.dir, ["test/all.rb"])
      assert_nil records.find { _1["kind"] == "switched" }, "tests slower than reading coverage stay per test"
    end
  end

  def test_a_subprocess_a_test_starts_records_its_lines_for_that_test
    minitest_project("test/cli_test.rb" => <<~'RUBY') do |p|
      require_relative "helper"
      require "open3"
      class CliTest < Minitest::Test
        def test_prints_total
          lib = File.expand_path("../lib", __dir__)
          out, = Open3.capture2(Gem.ruby, "-I", lib, "-e", 'require "cart"; print Cart.new([4, 5]).full?')
          assert_equal "false", out
        end
      end
    RUBY
      records = record(p.dir, ["test/all.rb"])
      child = records.find { _1["kind"] == "child" }
      refute_nil child, @output
      assert_equal "CliTest#test_prints_total", child["test"]
      assert_includes lines(child["cov"]["lib/cart.rb"]), 11
      assert_includes map.tests_touching("lib/cart.rb", 11..11).map { map.tests[_1].id }, "CliTest#test_prints_total"
      assert_equal 1, records.count { _1["kind"] == "boot" }, "the subprocess doesn't record a boot of its own"
    end
  end

  def test_a_fork_a_test_makes_records_its_lines_for_that_test
    skip "needs fork" unless Fixture.fork?
    minitest_project("test/fork_test.rb" => <<~RUBY) do |p|
      require_relative "helper"
      class ForkTest < Minitest::Test
        def test_in_a_fork
          pid = fork { Cart.new([1, 2, 3]).full? }
          Process.wait(pid)
          assert $?.success?
        end
      end
    RUBY
      records = record(p.dir, ["test/all.rb"])
      assert_includes map.tests_touching("lib/cart.rb", 11..11).map { map.tests[_1].id }, "ForkTest#test_in_a_fork"
      assert_empty records.select { _1["kind"] == "worker_boot" }, "a test's own fork isn't a parallel worker"
    end
  end

  # Rails' parallel testing: the main process loads everything, then forks workers that each run
  # some of the tests and report results back to it.
  def test_rails_parallel_workers
    skip "needs fork" unless Fixture.fork?
    skip "activesupport not installed" unless Fixture.latest("activesupport", 8)
    tests = (1..30).map { |i| "  test(\"total #{i}\") { assert_equal 0, Cart.new([]).total }\n" }.join
    files = {
      "lib/cart.rb" => CART,
      "test/helper.rb" => <<~RUBY,
        gem "minitest", "~> 5.0" # ActiveSupport 8.1 doesn't load under Minitest 6 yet
        require "active_support"
        require "active_support/test_case"
        require "active_support/testing/autorun"
        require_relative "../lib/cart"
        class ActiveSupport::TestCase
          parallelize(workers: 2, threshold: 0)
        end
      RUBY
      "test/total_test.rb" => "require_relative 'helper'\nclass TotalTest < ActiveSupport::TestCase\n#{tests}end\n",
      "test/full_test.rb" => <<~RUBY,
        require_relative "helper"
        class FullTest < ActiveSupport::TestCase
          test("full") { assert Cart.new([1, 2, 3]).full? }
        end
      RUBY
      "test/all.rb" => MINITEST["test/all.rb"]
    }
    Fixture.project(files) do |p|
      records = record(p.dir, ["test/all.rb"])
      workers = records.select { _1["kind"] == "worker_boot" }.map { _1["pid"] }
      assert_equal 2, workers.uniq.size, @output
      assert_equal workers.sort, records.select { _1["kind"] == "test" }.map { _1["pid"] }.uniq.sort, "tests ran in the workers"
      assert_equal 31, records.find { _1["kind"] == "summary" }["ran"], "the main process counts every worker's results"
      assert_empty map.warnings
      assert_equal ["FullTest#test_full"], map.tests_touching("lib/cart.rb", 11..11).map { map.tests[_1].id }
      assert_equal 30, map.tests_touching("lib/cart.rb", 7..7).size
      refute map.ran_during_boot?("lib/cart.rb", 7..7), "workers start before any test, so no test's lines count as boot"
    end
  end

  def test_tests_running_on_several_threads_are_refused
    minitest_project("test/threads_test.rb" => <<~RUBY) do |p|
      require_relative "helper"
      class ThreadsTest < Minitest::Test
        parallelize_me!
        20.times { |i| define_method("test_\#{i}") { sleep 0.01; assert Cart.new([i]).total } }
      end
    RUBY
      record(p.dir, ["test/all.rb"], env: { "MT_CPU" => "4", "N" => "4" })
      error = assert_raises(Pitstop::Map::Error) { map }
      assert_match "several threads at once", error.message
    end
  end

  def test_project_files_loaded_before_coverage_started_are_reported
    minitest_project("lib/early.rb" => "module Early\nend\n") do |p|
      env = { "RUBYOPT" => "-I#{p.dir}/lib -rearly -I#{Fixture::LIB} -rpitstop/record" }
      record(p.dir, ["test/all.rb"], env:)
      assert_match "1 project file loaded before coverage started, so no test is linked to it: lib/early.rb", map.warnings.join
    end
  end

  RSPEC = {
    "bin/rspec" => Fixture::RSPEC_BIN,
    "lib/stock.rb" => <<~RUBY,
      class Stock
        def self.seed
          @items = [1, 2]
        end

        def self.count
          @items.size
        end

        def self.empty?
          @items.empty?
        end
      end
    RUBY
    "spec/count_spec.rb" => <<~RUBY,
      require_relative "../lib/stock"
      RSpec.describe Stock do
        before(:all) { Stock.seed }
        it("counts") { expect(Stock.count).to eq 2 }
        context "inside" do
          it("is not empty") { expect(Stock.empty?).to be false }
        end
        it("is skipped", skip: "later") { Stock.count }
        it("fails") { expect(Stock.count).to eq 3 }
      end
    RUBY
    "spec/support/countable.rb" => <<~RUBY,
      RSpec.shared_examples "countable" do
        it("counts") { expect(Stock.count).to be >= 0 }
      end
    RUBY
    "spec/shared_spec.rb" => <<~RUBY
      require_relative "../lib/stock"
      require_relative "support/countable"
      RSpec.describe "a shelf" do
        before(:all) { Stock.seed }
        it_behaves_like "countable"
      end
    RUBY
  }.freeze

  def rspec(dir, *args, env: {}) = record(dir, ["bin/rspec", *args], env:, expect_success: false)

  def test_rspec_examples_shared_setup_and_shared_examples
    skip "rspec not installed" unless Fixture.rspec?
    Fixture.project(RSPEC) do |p|
      [1, 2, 3].each do |seed|
        records = rspec(p.dir, "--order", "rand:#{seed}")
        tests = tests_by_id(records)
        assert_equal %w[./spec/count_spec.rb[1:1] ./spec/count_spec.rb[1:2:1] ./spec/count_spec.rb[1:3] ./spec/count_spec.rb[1:4] ./spec/shared_spec.rb[1:1:1]],
                     tests.keys.sort, @output
        skipped = tests.delete("./spec/count_spec.rb[1:3]")
        assert_equal "skip", skipped["status"], "an example skipped up front is in the map, so it always runs"
        assert_nil skipped["cov"]
        assert_equal [7], lines(tests["./spec/count_spec.rb[1:1]"]["cov"]["lib/stock.rb"])
        assert_equal [11], lines(tests["./spec/count_spec.rb[1:2:1]"]["cov"]["lib/stock.rb"])
        assert_equal "fail", tests["./spec/count_spec.rb[1:4]"]["status"]
        assert_equal "spec/shared_spec.rb", tests["./spec/shared_spec.rb[1:1:1]"]["file"], "a shared example belongs to the file using it"

        # before(:all) ran Stock.seed once per file: every example in that file needs it.
        seeded = map.tests_touching("lib/stock.rb", 3..3).map { map.tests[_1].id }.sort
        assert_equal (tests.keys + ["./spec/count_spec.rb[1:3]"]).sort, seeded, "seed #{seed}"
        assert_equal 5, records.find { _1["kind"] == "summary" }["ran"]
        assert_empty map.warnings
      end
    end
  end

  # aggregate_failures raises its failure out through every around hook, past Pitstop's.
  def test_rspec_failures_raised_through_around_hooks_are_still_recorded
    skip "rspec not installed" unless Fixture.rspec?
    Fixture.project(RSPEC.merge("spec/aggregate_spec.rb" => <<~RUBY)) do |p|
      require_relative "../lib/stock"
      RSpec.describe "aggregated", :aggregate_failures do
        it("fails twice") { Stock.seed; expect(Stock.count).to eq 0; expect(Stock.empty?).to be true }
      end
    RUBY
      rspec(p.dir, "spec/aggregate_spec.rb")
      assert_match "Got 2 failures", @output
      test = map.tests.find { _1.id == "./spec/aggregate_spec.rb[1:1]" }
      assert_equal "fail", test.status, "RSpec decides it failed after every around hook returns"
      assert_equal [test.index], map.tests_touching("lib/stock.rb", 11..11).to_a
      assert_empty map.warnings
    end
  end

  # An error in before(:all) fails every example of the group without running any of them.
  def test_rspec_examples_failed_by_their_group_setup_are_in_the_map_as_failed
    skip "rspec not installed" unless Fixture.rspec?
    Fixture.project(RSPEC.merge("spec/setup_spec.rb" => <<~RUBY)) do |p|
      RSpec.describe "broken setup" do
        before(:all) { raise "no database" }
        it("one") { expect(1).to eq 1 }
        it("two") { expect(2).to eq 2 }
      end
    RUBY
      rspec(p.dir, "spec/setup_spec.rb")
      assert_equal [%w[./spec/setup_spec.rb[1:1] fail], %w[./spec/setup_spec.rb[1:2] fail]], map.tests.map { [_1.id, _1.status] }.sort
      assert_equal "spec/setup_spec.rb", map.tests.first.file
      assert_empty map.warnings
    end
  end

  def test_rspec_per_file
    skip "rspec not installed" unless Fixture.rspec?
    Fixture.project(RSPEC) do |p|
      records = rspec(p.dir, "--order", "rand:7", env: { "PITSTOP_GRANULARITY" => "file" })
      groups = records.select { _1["kind"] == "group" }.to_h { [_1["file"], _1] }
      assert_equal %w[spec/count_spec.rb spec/shared_spec.rb], groups.keys.sort
      assert_equal [3, 7, 11], lines(groups["spec/count_spec.rb"]["cov"]["lib/stock.rb"])
      assert_equal [3, 7], lines(groups["spec/shared_spec.rb"]["cov"]["lib/stock.rb"])
      assert_equal 3, groups["spec/count_spec.rb"]["tests"].size
    end
  end
end
