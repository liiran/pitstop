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
  def map(dirty: [], opened: nil)
    Pitstop::Map.new((opened || {}).merge(
      "version" => 1, "commit" => "abc", "dirty" => dirty, "framework" => "minitest",
      "unseen" => ["lib/shop/version.rb"], # loaded by the gemspec before coverage started
      "tests" => [
        ["CartTest#test_total", "test/cart_test.rb", 3, "pass", 1.0],
        ["CartTest#test_full", "test/cart_test.rb", 7, "pass", 1.0],
        ["CartsControllerTest#test_show", "test/carts_controller_test.rb", 3, "pass", 9.0],
        ["CartTest#test_broken", "test/cart_test.rb", 11, "fail", 1.0]
      ],
      "boot" => { "app/models/cart.rb" => [[1, 4], [8, 8], [12, 13]],
                  "lib/cop.rb" => [[1, 2]], "lib/registry.rb" => [[1, 2]], "lib/pricing.rb" => [[1, 2]] },
      "files" => {
        "app/models/cart.rb" => [[[[5, 5]], [0]], [[[9, 9]], [1]]],
        "app/views/carts/show.html.erb" => [[[[1, 3]], [2]]]
      },
      # Every method name there was, and the project's classes: something lists the public
      # methods of Cop, and the methods `Registry` itself has (`def self.x`).
      "methods" => %w[total full? label to_s initialize == on_send],
      "modules" => { "Cart" => "", "Cop" => "i", "Registry" => "c" }
    ))
  end

  def select(changes, now: { "app/models/cart.rb" => CART }, dirty: [], before: { "app/models/cart.rb" => CART }, mentioned: [], opened: nil, after_readers: true)
    changes = changes.map { |status, path, old| Pitstop::Git::Change.new(status:, path:, old_path: old) }
    Pitstop::Selector.new(
      map: map(dirty:, opened:), changes:,
      old_source: ->(path) { before[path] },
      new_source: ->(path) { now[path] },
      mentioned: ->(name) { mentioned.include?(name) }, after_readers:
    ).select
  end

  def ids(selection) = selection.tests.map { map.tests[_1].id }.sort - ["CartTest#test_broken"]

  def test_a_method_change_selects_only_the_tests_that_ran_it
    s = select([["M", "app/models/cart.rb"]], now: { "app/models/cart.rb" => CART.sub("items.sum", "items.sum + 1") })
    refute s.all?
    assert_equal ["CartTest#test_total"], ids(s)
    assert_includes s.reasons.map(&:what), "Cart#total changed"
  end

  # `bundle exec` loads a gem's gemspec, and the version file it requires, before Pitstop starts:
  # no test is linked to that file, so a change to it can't be narrowed.
  def test_a_file_loaded_before_recording_started_runs_everything
    s = select([["M", "lib/shop/version.rb"]], now: { "lib/shop/version.rb" => "VERSION = '1.1.0'\n" })
    assert s.all?
    assert_equal "loaded before Pitstop started recording, so no test is linked to it", s.reasons.first.what
  end

  def test_tests_that_failed_when_the_map_was_made_always_run
    s = select([["M", "README.md"]])
    assert_equal [3], s.tests.to_a
  end

  # A constant, a `validates`, an `include`: code outside methods runs when the file loads, before
  # the tests, so no test is linked to it. A test can depend on it without running a line of the
  # file (another file's method reads the constant), so narrowing to "the tests that ran the file"
  # would skip that test.
  def test_a_change_outside_methods_runs_everything
    s = select([["M", "app/models/cart.rb"]], now: { "app/models/cart.rb" => CART.sub("MAX = 3", "MAX = 4") })
    assert s.all?
    assert_equal "app/models/cart.rb: code outside methods changed: it runs when the file loads, so any test may depend on it", s.run_all
  end

  # `def label = "cart"` is on one line: that line runs when the file loads, and a call to it adds
  # nothing the coverage can tell apart. The same goes for a method with nothing in it, which is
  # what a Rails action that only renders looks like.
  def test_a_method_whose_calls_cant_be_seen_runs_everything
    s = select([["M", "app/models/cart.rb"]], now: { "app/models/cart.rb" => CART.sub('"cart"', '"basket"') })
    assert s.all?
    assert_match "Cart#label changed: a one-line or empty method, so calls to it can't be seen", s.run_all

    empty = "class CartsController\n  def show\n  end\nend\n"
    path = "app/controllers/carts_controller.rb"
    loaded = map
    loaded.boot[path] = [[1, 2]]
    s = Pitstop::Selector.new(
      map: loaded, changes: [Pitstop::Git::Change.new(status: "M", path:)],
      old_source: ->(_) { empty }, new_source: ->(_) { empty.sub("  end\nend", "    @cart = Cart.find(1)\n  end\nend") }
    ).select
    assert s.all?, "an empty action gets a first line: every test that requests it is affected, and none is linked to it"
  end

  # The one case that is certain: nothing loaded this file while the map was recorded (it isn't in
  # the map at all), so nothing in it can be changing what those tests do.
  def test_a_change_in_a_file_nothing_loaded_picks_nothing
    path = "saas/lib/billing.rb"
    was = "module Billing\n  RATE = 3\n\n  def self.due\n    RATE * 2\n  end\nend\n"
    [was.sub("RATE = 3", "RATE = 4"), was.sub("  def self.due", "  def self.late? = false\n\n  def self.due"), was.sub("RATE * 2", "RATE * 3")].each do |now|
      s = select([["M", path]], before: { path => was }, now: { path => now })
      refute s.all?, now
      assert_empty ids(s)
    end
    s = select([["M", path]], before: { path => was }, now: { path => was.sub("RATE = 3", "RATE = 4") })
    assert_equal "code outside methods changed, in a file no recorded test loaded", s.reasons.first.what
    refute select([["D", path]], before: { path => was }).all?
  end

  # A file with no code in it runs no line when it loads, so the map can't say whether it was
  # loaded. Code appearing in it counts as a change to a loaded file.
  def test_code_added_to_a_file_that_was_empty_runs_everything
    path = "app/models/concerns/taggable.rb"
    s = select([["M", path]], before: { path => "# to be written\n" }, now: { path => "module Taggable\n  LIMIT = 3\nend\n" })
    assert s.all?
  end

  # Gems kept inside the project (vendor/) are loaded, but the recorder leaves them out.
  def test_ruby_code_in_a_folder_the_map_doesnt_follow_runs_everything
    s = select([["M", "vendor/gems/money/lib/money.rb"]])
    assert s.all?
    assert_equal "vendor/gems/money/lib/money.rb: Ruby code in a folder the map doesn't follow", s.run_all
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

  # What a file defined when it loaded goes with it, and a renamed file is one gone and a new one.
  def test_deleted_and_renamed_ruby_files_run_everything
    deleted = select([["D", "app/models/cart.rb"]])
    assert deleted.all?
    assert_match "file deleted: any test may depend on what it defined", deleted.run_all
    assert select([["R", "app/models/basket.rb", "app/models/cart.rb"]]).all?
  end

  # The map saw a version of the file that isn't in git, so there is nothing to compare it with.
  def test_files_uncommitted_when_the_map_was_made
    assert select([], dirty: ["app/models/cart.rb"]).all?, "Ruby code: any part may differ, what runs on loading included"
    assert_equal ["CartsControllerTest#test_show"], ids(select([], dirty: ["app/views/carts/show.html.erb"])), "a template: the tests that rendered it"
    assert select([], dirty: ["Gemfile.lock"]).all?
    assert_empty ids(select([], dirty: ["README.md"]))
    refute select([], dirty: ["saas/lib/billing.rb"]).all?, "a Ruby file nothing loaded"
  end

  def test_a_removed_method_selects_the_tests_that_ran_it
    removed = CART.sub(/  def full\?\n.*?\n  end\n/m, "")
    s = select([["M", "app/models/cart.rb"]], now: { "app/models/cart.rb" => removed })
    assert_equal ["CartTest#test_full"], ids(s)
    assert_includes s.reasons.map(&:what), "Cart#full? removed"
  end

  def with_method(source) = { "app/models/cart.rb" => CART.sub("  def label", "#{source}\n\n  def label") }

  # A new method may replace one the class already answered to (`def to_s`, `def initialize`,
  # `def to_param` in a model): tests that relied on the old one needn't have run a line of this
  # file. Some class had a method called `to_s` when the map was recorded, so this may be that.
  def test_an_added_method_under_a_name_that_already_existed_runs_everything
    added = select([["M", "app/models/cart.rb"]], now: with_method("  def to_s\n    label\n  end"))
    assert added.all?
    assert_match "Cart#to_s added: a method of that name already existed, which it may replace", added.run_all
  end

  # Most added methods are helpers under a name nobody had: no class had such a method, and the
  # name appears nowhere in the project, so no existing code could have been calling it. What
  # calls it now is code changed in the same commit, picked for its own change.
  def test_an_added_method_under_a_name_nothing_used_before_is_narrowed
    added = select([["M", "app/models/cart.rb"]], now: with_method("  def discount_rate\n    5\n  end"))
    refute added.all?
    assert_equal ["CartTest#test_full", "CartTest#test_total"], ids(added)
    assert_equal "Cart#discount_rate added under a name nothing used before (every test that ran the file)", added.reasons.first.what
  end

  # The name is new to every class, but some code already says it: a template calling
  # `cart.discount_rate` behind a `respond_to?`, a `send(:discount_rate)`. It may reach the method now.
  def test_an_added_method_whose_name_the_project_already_used_runs_everything
    added = select([["M", "app/models/cart.rb"]], now: with_method("  def discount_rate\n    5\n  end"), mentioned: ["discount_rate"])
    assert added.all?
    assert_match "its name was already used in the project", added.run_all
  end

  # Code that lists a class's methods finds a new one without ever naming it. RuboCop runs a
  # cop's `on_send`, `on_def`... because they are in the cop's `public_instance_methods`: a new
  # `on_csend` starts running for every test whose code has a `&.` call. A private helper in the
  # same class isn't in that list.
  def test_a_method_added_to_a_class_whose_methods_get_listed
    cop = "class Cop\n  def on_send(node)\n    check(node)\n  end\n\n  private\n\n  def check(node)\n    node\n  end\nend\n"
    path = "lib/cop.rb"
    try = ->(now) { select([["M", path]], before: { path => cop }, now: { path => now }) }

    listed = try.(cop.sub("  private", "  def on_csend(node)\n    check(node)\n  end\n\n  private"))
    assert listed.all?
    assert_match "Cop#on_csend added: code lists the methods of Cop and can find it without naming it", listed.run_all

    refute try.(cop.sub("end\nend", "end\n\n  def safe_navigation?(node)\n    node.csend_type?\n  end\nend")).all?,
           "a private helper isn't among the public methods that get listed"

    registry = "class Registry\n  def self.all\n    @all\n  end\nend\n"
    with_class_method = select([["M", "lib/registry.rb"]], before: { "lib/registry.rb" => registry },
                                                           now: { "lib/registry.rb" => registry.sub("end\nend", "end\n\n  def self.enabled_cops\n    @all\n  end\nend") })
    assert with_class_method.all?, "the same for the class's own methods (`def self.x`), which `Registry.methods` lists"
  end

  # Nothing can be said about a class the recording didn't know (one defined in a way that leaves
  # it nameless, or a recording made before names were kept), or about a method put on some other
  # object (`def config.reset`).
  def test_an_added_method_the_recording_knows_nothing_about_runs_everything
    path = "lib/pricing.rb"
    was = "class Pricing\n  def rate\n    3\n  end\nend\n"
    unknown = select([["M", path]], before: { path => was }, now: { path => was.sub("end\nend", "end\n\n  def brand_new_helper\n    4\n  end\nend") })
    assert_match "Pricing wasn't a class the recording knew", unknown.run_all

    on_an_object = select([["M", "app/models/cart.rb"]], now: with_method("  def CONFIG.brand_new_helper\n    4\n  end"))
    assert_match "it may replace a method the class already had", on_an_object.run_all
  end

  def test_a_file_that_no_longer_parses_runs_everything
    broken = select([["M", "app/models/cart.rb"]], now: { "app/models/cart.rb" => CART.sub("def total", "def total(") })
    assert broken.all?
    assert_match(/doesn't parse/, broken.run_all)
  end

  # Nothing was recorded about a file that didn't exist, and a new file can take effect without
  # any other change naming it: Ruby files loaded with their whole folder or found by their name,
  # a layout named after a controller, data read with a glob.
  def test_new_files_run_everything
    assert_equal "app/models/coupon.rb: new Ruby file: it may be loaded by its name or its folder", select([["A", "app/models/coupon.rb"]]).run_all
    assert_equal "app/views/layouts/carts.html.erb: new template: it may be picked up by its name alone", select([["A", "app/views/layouts/carts.html.erb"]]).run_all
    assert select([["A", "app/data/rates.json"]]).all?
  end

  # A method with code of its own that no test ran, and that didn't run on loading either.
  def test_a_changed_method_no_test_ran_picks_nothing
    never_run = CART.sub("  def label = \"cart\"\n", "  def label = \"cart\"\n\n  def discount\n    total / 10\n  end\n")
    s = select([["M", "app/models/cart.rb"]], before: { "app/models/cart.rb" => never_run }, now: { "app/models/cart.rb" => never_run.sub("/ 10", "/ 5") })
    refute s.all?
    assert_empty ids(s)
  end

  def test_deleted_files
    assert_equal ["CartsControllerTest#test_show"], ids(select([["D", "app/views/carts/show.html.erb"]]))
    assert select([["D", "app/data/rates.json"]]).all?, "a deleted file no test was seen reading"
    deleted_test = select([["D", "test/cart_test.rb"]])
    assert_empty deleted_test.files
    assert_empty ids(deleted_test)
  end

  # The project is one folder of a repository: a file elsewhere in it shows up as "../...".
  # The map can't follow those, so only files that can't affect tests are let through.
  def test_files_elsewhere_in_the_repository
    harmless = select([["M", "../frontend/src/app.js"], ["A", "../docs/guide.md"], ["M", "../README.md"]])
    refute harmless.all?
    assert_empty ids(harmless)

    ["../common/lib/money.rb", "../common/data/rates.json", "../Gemfile.lock", "../other/test/x_test.rb"].each do |path|
      %w[M A D].each do |status|
        s = select([[status, path]])
        assert s.all?, "#{status} #{path}"
        assert_equal "#{path}: outside this project's folder, where the map can't follow it", s.run_all
      end
    end
  end

  def test_files_elsewhere_that_were_uncommitted_when_the_map_was_made
    assert select([], dirty: ["../common/lib/money.rb"]).all?
    refute select([], dirty: ["../frontend/app.js", "../notes.md"]).all?
  end

  def test_a_renamed_test_file_runs_whole_under_its_new_name
    s = select([["R", "test/basket_test.rb", "test/cart_test.rb"]])
    assert_equal ["test/basket_test.rb"], s.files.to_a
  end

  # --- files a test reads -------------------------------------------------------------------------

  # Tests 0 and 1 ran in one process, in that order; 2 and 3 in another.
  def reading(opened) = { "order" => [[0, 1], [2, 3]], "opened" => NOTHING_OPENED.merge(opened) }

  NOTHING_OPENED = { "reads" => {}, "lists" => {}, "boot_reads" => [], "boot_lists" => [], "file_reads" => {}, "file_lists" => {} }.freeze

  def test_the_tests_after_a_reader_count_only_in_its_own_process
    s = select([["M", "docs/a.md"]], opened: reading("reads" => { "docs/a.md" => [0] }))
    assert_equal %w[CartTest#test_full CartTest#test_total], ids(s)
  end

  # The template's lines are followed: a test that uses what was read from it runs it, and is
  # linked to it that way. So the reader is added, and not everything that ran after it.
  def test_a_file_whose_lines_are_followed_adds_its_readers_only
    s = select([["M", "app/views/carts/show.html.erb"]], opened: reading("reads" => { "app/views/carts/show.html.erb" => [0] }))
    assert_equal %w[CartTest#test_total CartsControllerTest#test_show], ids(s)
  end

  def test_a_renamed_file_counts_for_the_readers_of_its_old_name
    s = select([["R", "guides/a.md", "docs/a.md"]], opened: reading("reads" => { "docs/a.md" => [1] }))
    assert_equal %w[CartTest#test_full], ids(s)
  end

  # Before any test runs, the framework lists the test folder to find the test files. A new test
  # file is run whole because of exactly that, so the listing is no reason to run everything.
  # The same listing of any other folder is.
  def test_a_listing_made_while_the_app_starts_runs_everything_except_for_test_files
    opened = reading("boot_lists" => ["test/**/*_test.rb", "docs/*"])
    s = select([["A", "test/new_test.rb"]], opened:)
    refute s.all?
    assert_equal ["test/new_test.rb"], s.files.to_a

    assert select([["A", "docs/b.md"]], opened:).all?
    refute select([["M", "docs/b.md"]], opened:).all?, "an edit doesn't change which files there are"
  end

  def test_a_test_file_that_read_the_file_as_it_loaded_runs_whole
    s = select([["M", "docs/a.md"]], opened: reading("file_reads" => { "test/carts_controller_test.rb" => ["docs/a.md"] }))
    assert_equal ["test/carts_controller_test.rb"], s.files.to_a
    assert_equal %w[CartsControllerTest#test_show], ids(s)
  end

  def test_with_tests_after_readers_off_the_tests_after_a_reader_are_left_out
    s = select([["M", "docs/a.md"]], opened: reading("reads" => { "docs/a.md" => [0] }), after_readers: false)
    assert_equal %w[CartTest#test_total], ids(s)
  end
end
