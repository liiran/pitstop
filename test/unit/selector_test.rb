require "minitest/autorun"
require "pitstop/map"
require "pitstop/selector"

class SelectorTest < Minitest::Test
  CART = <<~RUBY
    class Cart
      MAX = 3

      def total
        items.sum
      end

      def full?
        items.size >= MAX
      end

      def label = "cart"
    end
  RUBY

  # Three tests: 0 ran Cart#total, 1 ran Cart#full?, 2 rendered the cart template. Test 3 failed.
  def map(dirty: [])
    Pitstop::Map.new(
      "version" => 1, "commit" => "abc", "dirty" => dirty, "framework" => "minitest",
      "tests" => [
        ["CartTest#test_total", "test/cart_test.rb", 3, "pass", 1.0],
        ["CartTest#test_full", "test/cart_test.rb", 7, "pass", 1.0],
        ["CartsControllerTest#test_show", "test/carts_controller_test.rb", 3, "pass", 9.0],
        ["CartTest#test_broken", "test/cart_test.rb", 11, "fail", 1.0]
      ],
      "boot" => { "app/models/cart.rb" => [[1, 4], [8, 8], [12, 13]] },
      "files" => {
        "app/models/cart.rb" => [[[[5, 5]], [0]], [[[9, 9]], [1]]],
        "app/views/carts/show.html.erb" => [[[[1, 3]], [2]]]
      }
    )
  end

  def select(changes, now: { "app/models/cart.rb" => CART }, dirty: [])
    changes = changes.map { |status, path, old| Pitstop::Git::Change.new(status:, path:, old_path: old) }
    Pitstop::Selector.new(
      map: map(dirty:), changes:,
      old_source: ->(path) { path == "app/models/cart.rb" ? CART : nil },
      new_source: ->(path) { now[path] }
    ).select
  end

  def ids(selection) = selection.tests.map { map.tests[_1].id }.sort - ["CartTest#test_broken"]

  def test_a_method_change_selects_only_the_tests_that_ran_it
    s = select([["M", "app/models/cart.rb"]], now: { "app/models/cart.rb" => CART.sub("items.sum", "items.sum + 1") })
    refute s.all?
    assert_equal ["CartTest#test_total"], ids(s)
    assert_includes s.reasons.map(&:what), "Cart#total changed"
  end

  def test_tests_that_failed_when_the_map_was_made_always_run
    s = select([["M", "README.md"]])
    assert_equal [3], s.tests.to_a
  end

  def test_a_skeleton_change_selects_every_test_that_ran_the_file
    s = select([["M", "app/models/cart.rb"]], now: { "app/models/cart.rb" => CART.sub("MAX = 3", "MAX = 4") })
    assert_equal ["CartTest#test_full", "CartTest#test_total"], ids(s)
  end

  def test_a_one_liner_no_test_was_seen_running_falls_back_to_the_file
    s = select([["M", "app/models/cart.rb"]], now: { "app/models/cart.rb" => CART.sub('"cart"', '"basket"') })
    assert_equal ["CartTest#test_full", "CartTest#test_total"], ids(s)
  end

  def test_a_method_that_runs_during_boot_runs_everything
    boot_map = map
    boot_map.boot["app/models/cart.rb"] << [5, 5]
    s = Pitstop::Selector.new(
      map: boot_map, changes: [Pitstop::Git::Change.new(status: "M", path: "app/models/cart.rb")],
      old_source: ->(_) { CART }, new_source: ->(_) { CART.sub("items.sum", "items.sum + 1") }
    ).select
    assert s.all?
    assert_match "Cart#total runs while the app boots", s.run_all
  end

  def test_templates_seen_in_coverage_are_followed
    assert_equal ["CartsControllerTest#test_show"], ids(select([["M", "app/views/carts/show.html.erb"]]))
  end

  def test_unknown_non_ruby_files_and_app_wide_files_run_everything
    assert select([["M", "app/views/carts/edit.html.erb"]]).all?
    assert select([["M", "Gemfile.lock"]]).all?
    refute select([["M", "app/assets/stylesheets/cart.css"]]).all?
    assert select([["D", "app/assets/images/logo.svg"]]).all?
  end

  def test_changed_and_new_test_files_run_whole
    s = select([["M", "test/cart_test.rb"], ["A", "test/new_test.rb"]])
    assert_equal %w[test/cart_test.rb test/new_test.rb], s.files.sort
    assert_equal ["CartTest#test_full", "CartTest#test_total"], ids(s)
  end

  def test_deleted_and_renamed_ruby_files
    assert_equal ["CartTest#test_full", "CartTest#test_total"], ids(select([["D", "app/models/cart.rb"]]))
    assert_equal ["CartTest#test_full", "CartTest#test_total"], ids(select([["R", "app/models/basket.rb", "app/models/cart.rb"]]))
  end

  def test_files_uncommitted_when_the_map_was_made_take_every_test_that_ran_them
    assert_equal ["CartTest#test_full", "CartTest#test_total"], ids(select([], dirty: ["app/models/cart.rb"]))
  end
end
