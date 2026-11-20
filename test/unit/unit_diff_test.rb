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

  def test_a_file_that_no_longer_parses
    assert_equal :unparsable, changes(BASE.sub("def total", "def total(")).first.kind
  end
end
