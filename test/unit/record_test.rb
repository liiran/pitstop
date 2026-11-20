require "minitest/autorun"
require "json"
require "tmpdir"
require "open3"
require "fileutils"

# Runs a tiny project's tests with the recorder loaded the way `pitstop record` loads it, and
# checks what each test (or test file) was said to run.
class RecordTest < Minitest::Test
  LIB = File.expand_path("../../lib", __dir__)

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

  def project
    Dir.mktmpdir("pitstop-record") do |dir|
      FileUtils.mkdir_p(["#{dir}/lib", "#{dir}/test"])
      File.write("#{dir}/lib/cart.rb", CART)
      File.write("#{dir}/test/total_test.rb", <<~RUBY)
        require_relative "../lib/cart"
        class TotalTest < Minitest::Test
          def test_total = assert_equal(3, Cart.new([1, 2]).total)
          def test_total_empty = assert_equal(0, Cart.new([]).total)
        end
      RUBY
      File.write("#{dir}/test/full_test.rb", <<~RUBY)
        require_relative "../lib/cart"
        class FullTest < Minitest::Test
          def test_full = assert(Cart.new([1, 2, 3]).full?)
          def test_not_full = refute(Cart.new([1]).full?)
        end
      RUBY
      File.write("#{dir}/test/all.rb", <<~RUBY)
        require "minitest/autorun"
        Dir[File.join(__dir__, "*_test.rb")].sort.each { require _1 }
      RUBY
      yield dir
    end
  end

  def record(dir, granularity:, seed:)
    out = "#{dir}/out-#{granularity}-#{seed}"
    env = { "RUBYOPT" => "-I#{LIB} -rpitstop/record", "PITSTOP_OUT" => out, "PITSTOP_ROOT" => dir,
            "PITSTOP_GRANULARITY" => granularity }
    output, status = Open3.capture2e(env, Gem.ruby, "test/all.rb", "--seed", seed.to_s, chdir: dir)
    assert status.success?, output
    Dir["#{out}/*.jsonl"].flat_map { |f| File.readlines(f).map { JSON.parse(_1) } }
  end

  def test_each_test_gets_only_the_lines_it_ran
    project do |dir|
      records = record(dir, granularity: "test", seed: 1)
      tests = records.select { _1["kind"] == "test" }.to_h { [_1["id"], _1] }
      assert_equal [[7, 7]], tests["TotalTest#test_total"]["cov"]["lib/cart.rb"].reject { _1 == [3, 3] }
      assert_equal [[11, 11]], tests["FullTest#test_full"]["cov"]["lib/cart.rb"].reject { _1 == [3, 3] }
      assert_equal "test/total_test.rb", tests["TotalTest#test_total"]["file"]
      refute tests.values.any? { _1["cov"].key?("test/total_test.rb") }, "test files themselves aren't recorded"
      boot = records.find { _1["kind"] == "boot" }
      assert_includes boot["cov"]["lib/cart.rb"], [1, 2], "class and method definitions run at boot"
    end
  end

  # Whatever order the files run in, a file's lines never leak into the file that ran before it.
  def test_per_file_recording_keeps_files_apart_in_any_order
    project do |dir|
      [1, 2, 3, 4].each do |seed|
        groups = record(dir, granularity: "file", seed:).select { _1["kind"] == "group" }.to_h { [_1["file"], _1] }
        total = groups.fetch("test/total_test.rb")["cov"]["lib/cart.rb"].flat_map { |a, b| (a..b).to_a }
        full = groups.fetch("test/full_test.rb")["cov"]["lib/cart.rb"].flat_map { |a, b| (a..b).to_a }
        assert_includes total, 7
        refute_includes total, 11, "seed #{seed}: FullTest's lines leaked into TotalTest's file"
        assert_includes full, 11
        refute_includes full, 7, "seed #{seed}: TotalTest's lines leaked into FullTest's file"
        assert_equal %w[TotalTest#test_total TotalTest#test_total_empty], groups["test/total_test.rb"]["tests"].sort
      end
    end
  end
end
