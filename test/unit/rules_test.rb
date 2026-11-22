require "minitest/autorun"
require "pitstop/rules"

class RulesTest < Minitest::Test
  def rules = Pitstop::Rules.new

  def kind(path) = rules.classify(path).kind

  def test_docs_and_ci_files_need_no_tests_at_any_depth
    %w[README.md docs/modules/ROOT/pages/usage/basic.adoc .github/workflows/ci.yml changelog/new_x.md
       bin/setup script/release Dockerfile saas/config/deploy.yml].each do |path|
      assert_equal :ignore, kind(path), path
    end
  end

  def test_app_wide_files_run_everything
    %w[Gemfile Gemfile.lock Gemfile.saas.lock rubocop.gemspec config/initializers/money.rb config/routes.rb
       db/schema.rb db/migrate/20260101_add_x.rb test/test_helper.rb spec/rails_helper.rb].each do |path|
      assert_equal :global, kind(path), path
    end
  end

  def test_test_files_and_test_support
    assert_equal :test, kind("test/models/cart_test.rb")
    assert_equal :test, kind("spec/rubocop/cop/style/foo_spec.rb")
    assert_equal :global, kind("test/test_helpers/session_test_helper.rb")
    assert_equal :global, kind("spec/support/cop_helper.rb")
  end

  def test_ruby_browser_and_other
    assert_equal :ruby, kind("app/models/cart.rb")
    assert_equal :ruby, kind("lib/tasks/cleanup.rake")
    assert_equal :browser, kind("app/assets/stylesheets/cards.css")
    assert_equal :browser, kind("app/javascript/controllers/x_controller.js")
    assert_equal :other, kind("app/views/carts/show.html.erb")
    assert_equal "template (not followed yet)", rules.classify("app/views/carts/show.html.erb").reason
    assert_equal "test fixture (not followed yet)", rules.classify("test/fixtures/cards.yml").reason
  end

  # The settings file decides what's ignored, so no pattern in it can make a change to the
  # settings file itself pick nothing.
  def test_no_pattern_can_ignore_the_settings_file
    custom = Pitstop::Rules.new("ignore" => ["**/*", ".pitstop.yml", ".*"])
    assert_equal :ignore, custom.classify("app/models/cart.rb").kind
    assert_equal :global, custom.classify(".pitstop.yml").kind
  end

  def test_overrides_add_to_the_defaults
    custom = Pitstop::Rules.new("ignore" => ["Gemfile.saas*"])
    assert_equal :ignore, custom.classify("Gemfile.saas.lock").kind
    assert_equal :global, custom.classify("Gemfile.lock").kind
  end
end
