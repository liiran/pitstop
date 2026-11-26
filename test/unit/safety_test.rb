require "minitest/autorun"
require "set"
require_relative "../support/project"
require_relative "../support/shop"

# What Pitstop does with input it shouldn't trust or didn't expect: a map file from somewhere
# else, odd file and test names, settings that try to hide changes, odd places to be installed
# or run from. Each case runs the real `pitstop` on a real project.
class SafetyTest < Minitest::Test
  def write_map(shop, data)
    Zlib::GzipWriter.open(File.join(shop.dir, ".pitstop", "map.json.gz")) { _1.write(JSON.generate(data)) }
  end

  # One plain line on stderr, no Ruby backtrace.
  def assert_plain_error(err, pattern)
    assert_match pattern, err
    assert_equal 1, err.lines.size, "expected one line, got:\n#{err}"
    assert err.start_with?("pitstop: "), err
  end

  # --- where it runs ----------------------------------------------------------------------------

  # A project that is one folder of a bigger repository: git reports paths from the top of the
  # repository, the map holds paths from the project's folder.
  def test_a_project_in_a_folder_of_a_bigger_repository
    Fixture.project({}) do |repo|
      Shop::FILES.each { |path, content| repo.write("backend/#{path}", content) }
      repo.write("frontend/app.js", "console.log(1)\n")
      repo.write("common/lib/shared.rb", "module Shared\n  X = 1\nend\n")
      repo.write("notes.md", "# Notes\n")
      repo.commit("start")
      code, out, err = repo.pitstop("record", at: "backend")
      assert_equal 0, code, out + err
      assert_empty repo.git("status", "--porcelain"), "recording leaves nothing for git to see"

      assert_equal [], repo.selection(at: "backend")["tests"], "nothing changed yet"

      repo.edit("backend/lib/cart.rb", "@items.sum", "@items.sum + 1")
      selection = repo.selection(at: "backend")
      assert_equal %w[CartTest#test_total], selection["tests"]
      assert_equal "lib/cart.rb", selection["reasons"].first["path"]
      code, out, = repo.pitstop("run", at: "backend")
      assert_equal 1, code, "the planted bug fails the one selected test"
      assert_match "Pitstop: ran 1 of 1 selected tests", out
      repo.git("checkout", "--", ".")

      # Elsewhere in the repository: files that can't affect tests pick nothing...
      repo.edit("frontend/app.js", "1", "2")
      repo.edit("notes.md", "Notes", "More notes")
      repo.write("frontend/new.css", "a {}\n")
      assert_equal [], repo.selection(at: "backend")["tests"]
      assert_nil repo.selection(at: "backend")["run_all"]

      # ...and code the map can't follow there runs everything, changed or brand new.
      repo.edit("common/lib/shared.rb", "X = 1", "X = 2")
      selection = repo.selection(at: "backend")
      assert_equal "../common/lib/shared.rb: outside this project's folder, where the map can't follow it", selection["run_all"]
      repo.git("checkout", "--", ".")
      repo.write("common/lib/added.rb", "module Added\nend\n")
      assert_match "../common/lib/added.rb: outside this project's folder", repo.selection(at: "backend")["run_all"]

      # The project can say which folders beside it don't matter.
      repo.write("backend/.pitstop.yml", "ignore: ['../common/**']\n")
      repo.commit("settings")
      repo.pitstop("record", at: "backend")
      repo.edit("common/lib/shared.rb", "X = 1", "X = 3")
      assert_nil repo.selection(at: "backend")["run_all"]
      assert_equal [], repo.selection(at: "backend")["tests"]
    end
  end

  def test_pitstop_installed_in_a_folder_with_a_space_in_its_name
    Dir.mktmpdir do |base|
      install = File.join(File.realpath(base), "my tools", "pit stop")
      FileUtils.mkdir_p(install)
      FileUtils.cp_r(Fixture::LIB, install)
      FileUtils.cp_r(File.dirname(Fixture::EXE), install)
      exe = File.join(install, "exe", "pitstop")
      Fixture.project(Shop::FILES) do |shop|
        shop.commit("start")
        code, out, err = shop.pitstop("record", exe:)
        assert_equal 0, code, out + err
        assert_match "mapped 5 tests", out
        shop.edit("lib/cart.rb", "@items.sum", "@items.sum(0)")
        code, out, err = shop.pitstop("run", exe:)
        assert_equal 0, code, out + err
        assert_match "Pitstop: ran 1 of 1 selected tests", out
      end
    end
  end

  def test_a_project_in_a_folder_with_spaces_and_accents
    Dir.mktmpdir do |base|
      dir = File.join(File.realpath(base), "my café project")
      Dir.mkdir(dir)
      shop = Fixture::Project.new(dir, Shop::FILES)
      shop.commit("start")
      code, out, err = shop.pitstop("record")
      assert_equal 0, code, out + err
      shop.edit("lib/price.rb", "cents / 100", "cents.div(100)")
      code, out, err = shop.pitstop("run")
      assert_equal 0, code, out + err
      assert_match "Pitstop: ran 2 of 2 selected tests", out
    end
  end

  # --- what it writes ---------------------------------------------------------------------------

  def test_everything_pitstop_writes_is_inside_dot_pitstop_and_out_of_git
    Fixture.project(Shop::FILES) do |shop|
      shop.commit("start")
      before = Dir.glob("**/*", File::FNM_DOTMATCH, base: shop.dir).reject { _1.start_with?(".git/") }.to_set
      shop.pitstop("record")
      shop.edit("lib/cart.rb", "@items.sum", "@items.sum(0)")
      shop.pitstop("list")
      code, = shop.pitstop("run")
      assert_equal 0, code
      shop.git("checkout", "--", ".")

      after = Dir.glob("**/*", File::FNM_DOTMATCH, base: shop.dir).reject { _1.start_with?(".git/") }.to_set
      added = (after - before).reject { File.directory?(File.join(shop.dir, _1)) }
      assert_equal %w[.pitstop/.gitignore .pitstop/map.json.gz], added.sort, "only the map, and the file that keeps it out of git"
      assert_empty shop.git("status", "--porcelain", "--untracked-files=all")
    end
  end

  # A shared map shouldn't say where on someone's disk the project (or anything else) lives.
  def test_the_map_holds_no_paths_outside_the_project
    Dir.mktmpdir do |elsewhere|
      elsewhere = File.realpath(elsewhere)
      File.write(File.join(elsewhere, "borrowed_test.rb"), <<~RUBY)
        require "cart"
        class BorrowedTest < Minitest::Test
          def test_label = assert_equal("cart", Cart.new([]).label)
        end
      RUBY
      loader = "require_relative 'test_helper'\nrequire #{File.join(elsewhere, 'borrowed_test.rb').inspect}\n"
      Fixture.project(Shop::FILES.merge("test/borrowing_test.rb" => loader)) do |shop|
        shop.commit("start")
        code, out, err = shop.pitstop("record")
        assert_equal 0, code, out + err
        map = shop.map
        borrowed = map["tests"].find { _1[0] == "BorrowedTest#test_label" }
        assert_nil borrowed[1], "a test class from outside the project has no file in the map"
        text = JSON.generate(map)
        [shop.dir, elsewhere, Dir.home].each { refute_includes text, _1 }

        # It's still a test like any other: a change to what it runs selects it, and it runs.
        shop.edit("lib/cart.rb", 'def label = "cart"', 'def label = "cart".to_s')
        assert_includes shop.selection["tests"], "BorrowedTest#test_label"
        code, out, err = shop.pitstop("run")
        assert_equal 0, code, out + err
        refute_match "didn't run", err
      end
    end
  end

  def test_saving_the_map_replaces_a_link_instead_of_writing_through_it
    Fixture.project(Shop::FILES) do |shop|
      shop.commit("start")
      Dir.mktmpdir do |elsewhere|
        victim = File.join(elsewhere, "important.txt")
        File.write(victim, "keep me")
        Dir.mkdir(File.join(shop.dir, ".pitstop"))
        begin
          File.symlink(victim, File.join(shop.dir, ".pitstop", "map.json.gz"))
        rescue NotImplementedError, SystemCallError
          skip "this system doesn't let tests make links"
        end
        code, out, err = shop.pitstop("record")
        assert_equal 0, code, out + err
        assert_equal "keep me", File.read(victim)
        refute File.symlink?(File.join(shop.dir, ".pitstop", "map.json.gz"))
        assert_equal 5, shop.map["tests"].size
      end
    end
  end

  # --- a map from somewhere else ----------------------------------------------------------------

  def test_a_damaged_or_made_up_map_is_refused_in_one_plain_line
    Shop.recorded do |shop|
      good = shop.map
      path = File.join(shop.dir, ".pitstop", "map.json.gz")
      marker = File.join(shop.dir, "PWNED.txt")
      tests = ->(change) { good["tests"].map(&:dup).tap { |list| change.(list[0]) } }
      made_up = {
        "a commit that is a git option" => good.merge("commit" => "--output=#{marker}"),
        "a short commit" => good.merge("commit" => "abc123"),
        "no commit" => good.merge("commit" => nil),
        "a test file above the project" => good.merge("tests" => tests.(->(t) { t[1] = "../outside_test.rb" })),
        "a test file anywhere on the disk" => good.merge("tests" => tests.(->(t) { t[1] = "/etc/passwd" })),
        "a test file on another drive" => good.merge("tests" => tests.(->(t) { t[1] = "D:evil_test.rb" })),
        "a made-up result" => good.merge("tests" => tests.(->(t) { t[3] = "maybe" })),
        "tests that aren't a list" => good.merge("tests" => "nope"),
        "no tests" => good.reject { |key, _| key == "tests" },
        "files that aren't a table" => good.merge("files" => [1, 2]),
        "a file above the project" => good.merge("files" => { "../../etc/x.rb" => [[[[1, 1]], [0]]] }),
        "a test number that doesn't exist" => good.merge("files" => { "lib/cart.rb" => [[[[1, 1]], [99]]] }),
        "lines that aren't numbers" => good.merge("boot" => { "lib/cart.rb" => [["1", "2"]] }),
        "method names that aren't a list of names" => good.merge("methods" => { "total" => true }),
        "a method name that isn't text" => good.merge("methods" => ["total", 7]),
        "classes that aren't a table" => good.merge("modules" => ["Cart"]),
        "a class with made-up marks" => good.merge("modules" => { "Cart" => "x; rm -rf" }),
        "a reader that isn't one of the tests" => good.merge("opened" => good["opened"].merge("reads" => { "docs/a.md" => [99] })),
        "a test file above the project, to run whole" => good.merge("opened" => good["opened"].merge("file_reads" => { "../x_test.rb" => ["docs/a.md"] })),
        "an order of tests that don't exist" => good.merge("order" => [[0, 99]]),
        "a list instead of a map" => [1, 2, 3]
      }
      made_up.each do |name, data|
        write_map(shop, data)
        %w[list run].each do |command|
          code, out, err = shop.pitstop(command)
          assert_equal 1, code, "#{name}: #{out}#{err}"
          assert_plain_error err, /isn't a (Pitstop map|map Pitstop wrote)/
        end
      end
      refute File.exist?(marker)

      damaged = { "not gzip" => "not gzip at all", "empty" => "", "half a map" => File.binread(path)[0, 40] }
      damaged.each do |name, bytes|
        File.binwrite(path, bytes)
        code, _, err = shop.pitstop("list")
        assert_equal 1, code, name
        assert_plain_error err, /(can't be read|isn't a Pitstop map).*run `pitstop record` again/
      end
      Zlib::GzipWriter.open(path) { _1.write("{not json") }
      code, _, err = shop.pitstop("list")
      assert_equal 1, code
      assert_plain_error err, /can't be read/

      write_map(shop, good)
      assert_equal 0, shop.pitstop("list").first, "the real map still loads"
    end
  end

  # --- settings ---------------------------------------------------------------------------------

  # An `ignore` pattern wide enough to match .pitstop.yml itself must not hide the change that
  # added it (with a planted bug riding along).
  def test_settings_cannot_hide_a_change_to_themselves
    Shop.recorded do |shop|
      shop.write(".pitstop.yml", "ignore: ['**/*', '.pitstop.yml']\n")
      shop.edit("lib/cart.rb", "@items.sum", "@items.sum + 1")
      assert_equal ".pitstop.yml: Pitstop's settings", shop.selection["run_all"]
      code, out, = shop.pitstop("run")
      assert_equal 1, code, "every test runs, and the bug is caught"
      assert_match "Running all 5 tests", out
    end
  end

  def test_settings_are_read_as_plain_data
    Shop.recorded do |shop|
      {
        "--- !ruby/object:Gem::Installer\ni: x\n" => /\.pitstop\.yml can't be read: Tried to load unspecified class/,
        "a: &a [x, x]\nignore: *a\n" => /\.pitstop\.yml can't be read: Alias parsing was not enabled/,
        "ignore: [unclosed\n" => /\.pitstop\.yml can't be read: did not find expected/,
        "command: []\n" => /command should be a list of words/,
        "command: ''\n" => /command should be a list of words/,
        "command: ['rake', '']\n" => /command should be a list of words/,
        "tests_after_readers: sometimes\n" => /tests_after_readers should be true or false/
      }.each do |yaml, message|
        shop.write(".pitstop.yml", yaml)
        code, _, err = shop.pitstop("list")
        assert_equal 64, code, yaml
        assert_plain_error err, message
      end
    end
  end

  # --- the test command -------------------------------------------------------------------------

  # The command is a list of words handed straight to the program. Nothing in it is read by a
  # shell, wherever it came from.
  def test_the_test_command_never_goes_through_a_shell
    Shop.recorded do |shop|
      shop.edit("lib/cart.rb", "@items.sum", "@items.sum(0)")
      made = File.join(shop.dir, "made-by-a-shell.txt")

      shop.write(".pitstop.yml", "command: ['echo hi > made-by-a-shell.txt']\n")
      %w[record run].each do |command|
        code, _, err = shop.pitstop(command)
        assert_equal 64, code, err
        assert_match "couldn't start", err
      end

      shop.delete(".pitstop.yml")
      code, _, err = shop.pitstop("run", "--", "echo hi > made-by-a-shell.txt & echo more")
      assert_equal 64, code
      assert_match "give the command as separate words", err
      refute File.exist?(made)

      # Words that would mean something to a shell reach the program as they are.
      shop.write("show_args.rb", "File.write('args.txt', ARGV.join('|'))\n")
      shop.pitstop("run", "--", Gem.ruby, "show_args.rb", "a;b", "$(echo x)", "c > d", "%PATH%")
      assert_equal "a;b|$(echo x)|c > d|%PATH%", shop.read("args.txt")
    end
  end

  # --- names --------------------------------------------------------------------------------------

  ODD_NAMES = <<~'RUBY'
    require_relative "test_helper"
    require "cart"

    class OddNamesTest < Minitest::Test
      define_method("test_with\ttab") { assert_equal 3, Cart.new([1, 2]).total }
      define_method("test_with\nnewline") { assert_equal 3, Cart.new([1, 2]).total }
      define_method("test_a\nfile test/price_test.rb") { assert_equal 3, Cart.new([1, 2]).total }
      define_method("test_with_\e[31mcolour\e[0m") { assert_equal 3, Cart.new([1, 2]).total }
      define_method("test_with_a_back\\slash_and_\\n") { assert_equal 3, Cart.new([1, 2]).total }
      define_method("test_été_✓") { assert_equal 3, Cart.new([1, 2]).total }
    end
  RUBY

  # A test's name can hold a tab, a newline or terminal colour codes. Each such test is still
  # recorded, selected and counted as itself; a name with a newline can't add a line to the
  # selection (here: one that would pull in a whole test file); and the codes aren't sent to the
  # terminal.
  def test_test_names_with_tabs_newlines_and_terminal_codes
    Fixture.project(Shop::FILES.merge("test/odd names_test.rb" => ODD_NAMES, "test/-n_test.rb" => ODD_NAMES.sub("OddNamesTest", "DashTest"))) do |shop|
      shop.commit("start")
      code, out, err = shop.pitstop("record")
      assert_equal 0, code, out + err
      assert_match "mapped 17 tests", out

      shop.edit("lib/cart.rb", "@items.sum", "@items.sum(0)")
      code, out, err = shop.pitstop("list", "--explain")
      assert_equal 0, code, err
      assert_match "Would run 13 of 17 tests", out
      refute_match(/\e/, out, "colour codes are shown, not sent")
      assert_includes out, 'OddNamesTest#test_with_\e[31mcolour\e[0m  test/odd names_test.rb'
      assert_includes out, 'OddNamesTest#test_with\nnewline  test/odd names_test.rb'
      assert_includes out, "DashTest#test_été_✓  test/-n_test.rb"

      code, out, err = shop.pitstop("run")
      assert_equal 0, code, out + err
      assert_match "Pitstop: ran 13 of 13 selected tests\n", out
      assert_match(/^13 runs, /, out, "test/price_test.rb wasn't pulled in")
    end
  end

  def test_spec_files_with_odd_names
    skip "rspec not installed" unless Fixture.rspec?
    spec = "require 'cart'\nRSpec.describe Cart do\n  it('adds') { expect(Cart.new([1, 2]).total).to eq 3 }\nend\n"
    files = { "bin/rspec" => Fixture::RSPEC_BIN, ".rspec" => "-I lib\n", "lib/cart.rb" => Shop::CART, "spec/plain_spec.rb" => spec,
              "spec/100% ^odd& (name)_spec.rb" => spec, "spec/sub dir/-dash_spec.rb" => spec }
    Fixture.project(files) do |shop|
      shop.commit("start")
      code, out, err = shop.pitstop("record", "--", Gem.ruby, "bin/rspec")
      assert_equal 0, code, out + err
      shop.edit("lib/cart.rb", "@items.sum", "@items.sum(0)")
      code, out, err = shop.pitstop("run", "--", Gem.ruby, "bin/rspec")
      assert_equal 0, code, out + err
      assert_match "Pitstop: ran 3 of 3 selected tests", out
    end
  end

  # --- other processes ----------------------------------------------------------------------------

  # A test can start Ruby with almost nothing of its own environment. Pitstop's hook is still
  # named in RUBYOPT there, and must leave that process alone.
  def test_a_ruby_process_started_with_a_bare_environment_is_left_alone
    bare = <<~RUBY
      require_relative "test_helper"
      require "open3"
      require "cart"

      class BareTest < Minitest::Test
        def test_a_bare_subprocess
          keep = %w[RUBYOPT RUBYLIB PATH SystemRoot GEM_PATH].to_h { [_1, ENV[_1]] }.compact
          out, status = Open3.capture2e(keep, Gem.ruby, "-e", "print 1 + 1", unsetenv_others: true)
          assert status.success?, out
          assert_equal "2", out
          assert_equal 3, Cart.new([1, 2]).total
        end
      end
    RUBY
    Fixture.project(Shop::FILES.merge("test/bare_test.rb" => bare)) do |shop|
      shop.commit("start")
      code, out, err = shop.pitstop("record")
      assert_equal 0, code, out + err
      shop.edit("lib/cart.rb", "@items.sum", "@items.sum(0)")
      code, out, err = shop.pitstop("run")
      assert_equal 0, code, out + err
      assert_match "Pitstop: ran 2 of 2 selected tests", out
    end
  end

  # --- other gems --------------------------------------------------------------------------------

  # minitest-reporters replaces Minitest::Test#run by renaming it. A wrapper Pitstop had put
  # around `run` first made the renamed method call itself until the stack ran out, in every
  # test, while recording and while running.
  def test_a_gem_that_renames_minitests_run_method
    skip "minitest-reporters not installed" unless Fixture.latest("minitest-reporters", 1)
    helper = <<~RUBY
      gem "minitest", ENV["MT_VERSION"] if ENV["MT_VERSION"]
      require "minitest/autorun"
      require "minitest/reporters"
      Minitest::Reporters.use! Minitest::Reporters::BaseReporter.new
      $LOAD_PATH.unshift File.expand_path("../lib", __dir__)
    RUBY
    Fixture.minitest_versions.each do |version|
      Fixture.project(Shop::FILES.merge("test/test_helper.rb" => helper)) do |shop|
        shop.commit("start")
        env = { "MT_VERSION" => version }
        code, out, err = shop.pitstop("record", env:)
        assert_equal 0, code, "Minitest #{version}: #{out}#{err}"
        assert_match "mapped 5 tests", out
        assert_empty err

        shop.edit("lib/price.rb", "cents / 100", "cents.div(100)")
        assert_equal %w[PriceTest#test_format ReceiptTest#test_prints_a_price], shop.selection["tests"].sort
        code, out, err = shop.pitstop("run", env:)
        assert_equal 0, code, "Minitest #{version}: #{out}#{err}"
        assert_match "Pitstop: ran 2 of 2 selected tests", out
      end
    end
  end

  # Ctrl-C, or a CI job being cancelled, while the tests run: the test command stops too, the
  # run's working files are removed, and Pitstop ends the way a stopped program does.
  def test_stopping_pitstop_stops_the_test_command_and_cleans_up
    skip "Windows has no signals to send" if Gem.win_platform?
    slow = <<~RUBY
      require_relative "test_helper"
      require "cart"

      class SlowTest < Minitest::Test
        def test_slow
          assert_equal 3, Cart.new([1, 2]).total
          return unless File.exist?("slow.flag")

          File.write("test.pid", Process.pid.to_s)
          sleep 60
        end
      end
    RUBY
    Fixture.project(Shop::FILES.merge("test/slow_test.rb" => slow, ".gitignore" => "slow.flag\ntest.pid\n")) do |shop|
      shop.commit("start")
      command = ["--", Gem.ruby, "-Itest", "-e", 'Dir["test/*_test.rb"].each { require "./#{_1}" }']
      code, out, err = shop.pitstop("record", *command)
      assert_equal 0, code, out + err
      shop.edit("lib/cart.rb", "@items.sum", "@items.sum(0)")
      shop.write("slow.flag", "")

      { "INT" => 130, "TERM" => nil }.each do |signal, exit_status|
        pitstop = Process.spawn(Fixture::CLEAN_ENV, Gem.ruby, Fixture::EXE, "run", *command, chdir: shop.dir, out: File::NULL, err: File::NULL)
        pid_file = File.join(shop.dir, "test.pid")
        100.times { File.exist?(pid_file) ? break : sleep(0.1) }
        assert File.exist?(pid_file), "the slow test never started"
        test_process = File.read(pid_file).to_i
        Process.kill(signal, pitstop)
        _, status = Process.wait2(pitstop)

        if exit_status
          assert_equal exit_status, status.exitstatus
        else
          assert status.signaled?, "ends by the signal, as any stopped program does"
        end
        assert_empty Dir[File.join(shop.dir, ".pitstop", "ran-*")], "working files are removed"
        gone = 50.times.any? do
          Process.kill(0, test_process)
          sleep 0.1
          false
        rescue Errno::ESRCH
          true
        end
        assert gone, "the test command was stopped too (#{signal})"
        File.delete(pid_file)
      end
    end
  end

  # Ruby has one coverage counter. While recording it's Pitstop's, so SimpleCov is switched off
  # (it would report nothing covered and fail a minimum); in `pitstop run` it works as usual, and
  # the project's test setup can tell which is which from PITSTOP.
  def test_simplecov_is_off_while_recording_and_untouched_when_running
    skip "simplecov not installed" unless Fixture.latest("simplecov", 0) || Fixture.latest("simplecov", 1)
    helper = <<~RUBY
      require "simplecov"
      SimpleCov.start do
        minimum_coverage 90 unless ENV["PITSTOP"] == "run" # a partial run covers part of the code
      end
      File.write("mode.txt", ENV.fetch("PITSTOP", "none"))
      require "minitest/autorun"
      $LOAD_PATH.unshift File.expand_path("../lib", __dir__)
    RUBY
    Fixture.project(Shop::FILES.merge("test/test_helper.rb" => helper, ".gitignore" => "coverage/\nmode.txt\n")) do |shop|
      shop.commit("start")
      code, out, err = shop.pitstop("record")
      assert_equal 0, code, out + err
      assert_match "pitstop: SimpleCov is off while recording", err
      refute Dir.exist?(File.join(shop.dir, "coverage")), "no empty coverage report is written"
      assert_equal "record", shop.read("mode.txt")
      assert_equal 5, shop.map["tests"].size

      shop.edit("lib/cart.rb", "@items.sum", "@items.sum(0)")
      code, out, err = shop.pitstop("run")
      assert_match "Pitstop: ran 1 of 1 selected tests", out
      assert_equal "run", shop.read("mode.txt")
      assert Dir.exist?(File.join(shop.dir, "coverage")), "SimpleCov ran as usual:\n#{out}#{err}"
      assert_equal 0, code, out + err
    end
  end
end
