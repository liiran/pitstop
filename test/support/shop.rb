# A small Minitest project: a cart, a price formatter, and tests for each. One test runs a Ruby
# subprocess, so the subprocess's lines must still be linked to it.
module Shop
  CART = <<~RUBY
    class Cart
      MAX = 3

      def initialize(items)
        @items = items
      end

      def total
        @items.sum
      end

      def full?
        @items.size >= MAX
      end

      def label = "cart"
    end
  RUBY

  PRICE = <<~RUBY
    module Price
      def self.format(cents)
        "$\#{cents / 100}.\#{(cents % 100).to_s.rjust(2, "0")}"
      end
    end
  RUBY

  HELPER = <<~RUBY
    gem "minitest", ENV["MT_VERSION"] if ENV["MT_VERSION"]
    require "minitest/autorun"
    $LOAD_PATH.unshift File.expand_path("../lib", __dir__)
  RUBY

  CART_TEST = <<~RUBY
    require_relative "test_helper"
    require "cart"

    class CartTest < Minitest::Test
      def test_total
        assert_equal 3, Cart.new([1, 2]).total
      end

      def test_full
        assert Cart.new([1, 2, 3]).full?
        refute Cart.new([1]).full?
      end

      def test_label
        assert_equal "cart", Cart.new([]).label
      end
    end
  RUBY

  PRICE_TEST = <<~RUBY
    require_relative "test_helper"
    require "price"

    class PriceTest < Minitest::Test
      def test_format
        assert_equal "$1.05", Price.format(105)
      end
    end
  RUBY

  # Formats a price in a separate Ruby process, the way a test of a command-line tool would.
  RECEIPT_TEST = <<~RUBY
    require_relative "test_helper"
    require "open3"

    class ReceiptTest < Minitest::Test
      def test_prints_a_price
        lib = File.expand_path("../lib", __dir__)
        out, status = Open3.capture2(Gem.ruby, "-I", lib, "-e", 'require "price"; print Price.format(250)')
        assert status.success?
        assert_equal "$2.50", out
      end
    end
  RUBY

  RAKEFILE = <<~RUBY
    require "rake/testtask"
    Rake::TestTask.new do |t|
      t.libs << "test"
      t.pattern = "test/**/*_test.rb"
      t.warning = false
    end
  RUBY

  FILES = {
    "lib/cart.rb" => CART, "lib/price.rb" => PRICE, "test/test_helper.rb" => HELPER,
    "test/cart_test.rb" => CART_TEST, "test/price_test.rb" => PRICE_TEST, "test/receipt_test.rb" => RECEIPT_TEST,
    "Rakefile" => RAKEFILE, "README.md" => "# Shop\n"
  }.freeze

  # A recorded shop: committed, then `pitstop record` run once (with the default `rake test`).
  def self.recorded(env: {})
    Fixture.project(FILES) do |shop|
      shop.commit("start")
      code, out, err = shop.pitstop("record", env:)
      raise "pitstop record failed (#{code}):\n#{out}\n#{err}" unless code.zero?

      yield shop, out, err
    end
  end
end
