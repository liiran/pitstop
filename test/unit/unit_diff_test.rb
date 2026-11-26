require "minitest/autorun"
require "pitstop/unit_diff"

class UnitDiffTest < Minitest::Test
  BASE = <<~'RUBY'
    class Cart
      MAX = 3
      scope :recent, -> { order(:id) }

      def total
        items.sum
      end

      def full?
        items.size >= MAX
      end

      def self.build = new

      class << self
        def sql(x)
          <<~SQL
            select #{x}
          SQL
        end
      end
    end
  RUBY

  def changes(new_source) = Pitstop::UnitDiff.compare(BASE, new_source)

  def summary(new_source) = changes(new_source).map { [_1.kind, _1.key] }

  def test_identical_files_have_no_changes
    assert_empty changes(BASE)
  end

  def test_comments_and_whitespace_do_not_count
    edited = BASE.sub("items.sum", "items.sum   # add them up").sub("def full?", "# Is it full?\n  def full?")
    assert_empty changes(edited)
  end

  def test_a_method_body_change_names_the_method_with_its_old_lines
    found = changes(BASE.sub("items.sum", "items.sum + 1"))
    assert_equal [[:changed, "Cart#total"]], found.map { [_1.kind, _1.key] }
    assert_equal 5..7, found.first.old_lines
  end

  # The coverage shows a call as the unit's own lines running. A unit with no line of its own
  # (everything on the line that opens it, which also runs when the file loads, or nothing in it
  # at all) can't be linked to the tests that call it.
  def test_units_whose_calls_the_coverage_cant_see
    source = <<~RUBY
      class Cart
        scope :recent, -> { order(:id) }
        scope :old, -> do
          order(:id)
        end
        def self.build = new
        def label; "cart"; end
        def show
        end
        def total
          items.sum
        rescue
          0
        end
      end
    RUBY
    blind = Pitstop::UnitDiff.compare(source, "class Cart\nend\n").select { _1.kind == :removed }.to_h { [_1.key, _1.blind] }
    assert_equal({ "Cart scope(:recent) ->" => true, "Cart scope(:old) ->" => false, "Cart.build" => true,
                   "Cart#label" => true, "Cart#show" => true, "Cart#total" => false }, blind)
  end

  # An added method comes with its name, its class, which side it is on and whether the file
  # shows it to be private.
  def test_an_added_method_says_what_the_file_shows_about_it
    before = "class Cart\nend\n"
    after = <<~RUBY
      class Cart
        def shown
          1
        end

        def self.build
          new
        end

        private def tucked_away
          2
        end

        def named_later
          3
        end
        private :named_later

        private

        def after_private
          4
        end

        public

        def shown_again
          5
        end

        class << self
          def listed
            6
          end

          private

          def unlisted
            7
          end
        end

        def self.made_private
          8
        end
        private_class_method :made_private

        def CONFIG.elsewhere
          9
        end
      end
    RUBY
    added = Pitstop::UnitDiff.compare(before, after).select { _1.kind == :added }.to_h { [_1.key, _1.unit] }
    seen = added.transform_values { |unit| unit.method && [unit.owner, unit.class_side ? :class : :instance, unit.hidden ? :private : :public] }
    assert_equal({
      "Cart#shown" => ["Cart", :instance, :public], "Cart.build" => ["Cart", :class, :public],
      "Cart#tucked_away" => ["Cart", :instance, :private], "Cart#named_later" => ["Cart", :instance, :private],
      "Cart#after_private" => ["Cart", :instance, :private], "Cart#shown_again" => ["Cart", :instance, :public],
      "Cart.listed" => ["Cart", :class, :public], "Cart.unlisted" => ["Cart", :class, :private],
      "Cart.made_private" => ["Cart", :class, :private], "Cart.elsewhere" => nil
    }, seen)
  end

  def test_pure_insertion_inside_a_method_is_a_change_to_that_method
    assert_equal [[:changed, "Cart#full?"]], summary(BASE.sub("items.size >= MAX", "return false if items.empty?\n    items.size >= MAX"))
  end

  def test_class_methods_singleton_blocks_lambdas_and_heredocs
    assert_equal [[:changed, "Cart.build"]], summary(BASE.sub("def self.build = new", "def self.build = new(1)"))
    assert_equal [[:changed, "Cart scope(:recent) ->"]], summary(BASE.sub("order(:id)", "order(:name)"))
    found = changes(BASE.sub('select #{x}', 'select #{x} limit 1'))
    assert_equal [[:changed, "Cart.sql"]], found.map { [_1.kind, _1.key] }
    assert_equal 16..20, found.first.old_lines, "a heredoc's text belongs to the method that opens it"
  end

  def test_code_outside_units_is_a_skeleton_change
    assert_equal [[:skeleton, nil]], summary(BASE.sub("MAX = 3", "MAX = 4"))
  end

  def test_removed_and_added_units
    removed = BASE.sub(/  def full\?\n.*?\n  end\n/m, "")
    assert_equal [[:removed, "Cart#full?"]], summary(removed)
    added = BASE.sub("  def self.build", "  def empty? = items.empty?\n\n  def self.build")
    assert_equal [[:added, "Cart#empty?"]], summary(added)
  end

  def test_moving_a_method_changes_the_skeleton_because_order_can_matter
    swapped = BASE.sub(/(  def total\n.*?\n  end\n)\n(  def full\?\n.*?\n  end\n)/m, "\\2\n\\1")
    refute_equal BASE, swapped
    assert_equal [[:skeleton, nil]], summary(swapped)
  end

  CONCERN = <<~'RUBY'
    module Shop
      module Billing
        class Invoice < Base
          included do
            before_save { self.total ||= 0 }
          end

          class_methods do
            def build = new
          end

          private def secret
            42
          end

          define_method(:doubled) { total * 2 }

          def twice
            1
          end

          def twice
            2
          end
        end
      end
    end

    class Shop::Cart
      def self.make = new
    end
  RUBY

  def concern(from, to) = Pitstop::UnitDiff.compare(CONCERN, CONCERN.sub(from, to)).map { [_1.kind, _1.key] }

  def test_names_follow_nesting_concerns_and_modifiers
    assert_equal [[:changed, "Shop::Billing::Invoice before_save"]], concern("||= 0", "||= 1")
    assert_equal [[:changed, "Shop::Billing::Invoice.build"]], concern("def build = new", "def build = new(1)"), "class_methods do… defines class methods"
    assert_equal [[:changed, "Shop::Billing::Invoice#secret"]], concern("42", "43")
    assert_equal [[:changed, "Shop::Billing::Invoice define_method(:doubled)"]], concern("total * 2", "total * 3")
    assert_equal [[:changed, "Shop::Cart.make"]], concern("def self.make = new", "def self.make = new(1)")
  end

  # The second `twice` replaces the first; each is its own unit, numbered in order.
  def test_a_method_defined_twice
    assert_equal [[:changed, "Shop::Billing::Invoice#twice (2)"]], concern("      2\n", "      3\n")
    found = Pitstop::UnitDiff.compare(CONCERN, CONCERN.sub(/      def twice\n        2\n      end\n/, ""))
    assert_equal [[:removed, "Shop::Billing::Invoice#twice (2)"]], found.map { [_1.kind, _1.key] }
  end

  def test_a_file_that_no_longer_parses
    assert_equal :unparsable, changes(BASE.sub("def total", "def total(")).first.kind
  end
end
