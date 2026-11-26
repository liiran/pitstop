require "minitest/autorun"
require "tmpdir"
require "json"
require "pitstop/map"

# Merging what the test processes wrote into one map, from hand-written records.
class MapTest < Minitest::Test
  COMMIT = "c0ffee".ljust(40, "0")
  RAN = { "lib/cart.rb" => [[1, 1]] }.freeze # some line of the project, for tests about something else

  def build(*shards, dirty: [])
    Dir.mktmpdir do |dir|
      shards.each_with_index do |records, i|
        File.write(File.join(dir, "#{100 + i}.jsonl"), records.map { JSON.generate(_1) + "\n" }.join)
      end
      Pitstop::Map.build(dir, commit: COMMIT, dirty:)
    end
  end

  def rec(id, cov: nil, file: "test/cart_test.rb", status: "pass")
    { "kind" => "test", "framework" => "minitest", "id" => id, "file" => file, "line" => 1, "status" => status,
      "ms" => 1.0, "cov" => cov }.compact
  end

  def summary(ran) = { "kind" => "summary", "framework" => "minitest", "ran" => ran }

  def ids(map, path, lines = nil) = map.tests_touching(path, lines).map { map.tests[_1].id }.sort

  def test_tests_that_ran_the_same_lines_share_one_entry
    map = build([rec("A#a", cov: { "lib/cart.rb" => [[5, 5]] }), rec("A#b", cov: { "lib/cart.rb" => [[5, 5]] }),
                 rec("A#c", cov: { "lib/cart.rb" => [[9, 9]] }), summary(3)])
    assert_equal [[[[5, 5]], [0, 1]], [[[9, 9]], [2]]], map.files["lib/cart.rb"]
    assert_equal %w[A#a A#b], ids(map, "lib/cart.rb", 5..5)
    assert_equal %w[A#c], ids(map, "lib/cart.rb", 8..10)
    assert_empty ids(map, "lib/cart.rb", 6..8)
    assert_empty map.warnings
  end

  def test_workers_write_separate_files_and_a_retried_test_keeps_its_last_run
    map = build([rec("A#a", cov: { "lib/a.rb" => [[1, 1]] }, status: "fail")],
                [rec("A#b", cov: { "lib/b.rb" => [[1, 1]] }), rec("A#a", cov: { "lib/a.rb" => [[2, 2]] }), summary(3)])
    assert_equal %w[A#a A#b], map.tests.map(&:id)
    assert_equal "pass", map.tests[0].status
    assert_equal %w[A#a], ids(map, "lib/a.rb")
    assert_equal %w[A#b], ids(map, "lib/b.rb")
  end

  def test_per_file_groups_give_every_test_in_the_file_the_files_lines
    map = build([rec("A#a"), rec("A#b"), rec("B#c", file: "test/b_test.rb"),
                 { "kind" => "group", "file" => "test/cart_test.rb", "tests" => %w[A#a A#b], "cov" => { "lib/cart.rb" => [[3, 4]] } },
                 { "kind" => "group", "file" => "test/b_test.rb", "tests" => %w[B#c], "cov" => { "lib/b.rb" => [[1, 1]] } }, summary(3)])
    assert_equal %w[A#a A#b], ids(map, "lib/cart.rb")
    assert_equal %w[B#c], ids(map, "lib/b.rb")
  end

  def test_shared_spec_file_setup_goes_to_every_test_in_that_file
    map = build([rec("./spec/a_spec.rb[1:1]", file: "spec/a_spec.rb"), rec("./spec/a_spec.rb[1:2]", file: "spec/a_spec.rb"),
                 rec("./spec/b_spec.rb[1:1]", file: "spec/b_spec.rb"),
                 { "kind" => "between", "file" => "spec/a_spec.rb", "cov" => { "lib/seed.rb" => [[2, 3]] } }, summary(3)])
    assert_equal %w[./spec/a_spec.rb[1:1] ./spec/a_spec.rb[1:2]], ids(map, "lib/seed.rb")
  end

  def test_a_subprocess_s_lines_belong_to_the_test_that_started_it
    map = build([rec("A#a", cov: { "lib/cart.rb" => [[1, 1]] }), rec("A#b"), summary(2)],
                [{ "kind" => "child", "test" => "A#b", "cov" => { "lib/price.rb" => [[2, 3]] } },
                 { "kind" => "child", "test" => "Gone#x", "cov" => { "lib/other.rb" => [[1, 1]] } }])
    assert_equal %w[A#b], ids(map, "lib/price.rb")
    refute map.covered?("lib/other.rb"), "a child of an unknown test is dropped"
  end

  def test_boot_lines_from_every_process_are_merged
    map = build([{ "kind" => "boot", "cov" => { "lib/cart.rb" => [[1, 2], [7, 7]] }, "unseen" => [] }, rec("A#a"), summary(1)],
                [{ "kind" => "worker_boot", "cov" => { "lib/cart.rb" => [[3, 3], [7, 8]] } }])
    assert_equal [[1, 3], [7, 8]], map.boot["lib/cart.rb"]
    assert map.ran_during_boot?("lib/cart.rb", 8..9)
    refute map.ran_during_boot?("lib/cart.rb", 4..6)
  end

  # Every process leaves the names it had: a class one of them listed the methods of, a method
  # only a subprocess defined. All of it counts.
  def test_method_names_and_classes_from_every_process_are_merged
    map = Dir.mktmpdir do |dir|
      File.write(File.join(dir, "100.jsonl"), [rec("A#a", cov: RAN), summary(1)].map { JSON.generate(_1) + "\n" }.join)
      File.write(File.join(dir, "names-3-1.json"), JSON.generate("methods" => %w[total to_s], "modules" => { "Cart" => "", "Cop" => "i" }))
      File.write(File.join(dir, "names-3-2.json"), JSON.generate("methods" => %w[to_s on_send], "modules" => { "Cart" => "I", "Cop" => "ic" }))
      Pitstop::Map.build(dir, commit: COMMIT)
    end
    assert map.method?("total")
    assert map.method?("on_send")
    refute map.method?("brand_new_helper")
    assert_equal "I", map.module_marks("Cart")
    assert_equal "ci", map.module_marks("Cop")
    assert_nil map.module_marks("Unknown")
  end

  # A recording that kept no names can't say a name is new.
  def test_without_recorded_names_every_method_name_counts_as_known
    map = build([rec("A#a", cov: RAN), summary(1)])
    assert map.method?("brand_new_helper")
    assert_nil map.module_marks("Cart")
  end

  def test_warns_when_the_framework_ran_more_tests_than_were_recorded
    one = rec("A#a", cov: RAN)
    assert_match "2 of 3 tests ran without being recorded", build([one, summary(3)]).warnings.join
    named = summary(2).merge("framework" => "rspec", "unrecorded" => ["./spec/a_spec.rb[1:2]"])
    assert_match "only run when their own test file changes: ./spec/a_spec.rb[1:2]", build([one, named]).warnings.join
    assert_match "never reported its total", build([one]).warnings.join
    assert_empty build([one, rec("A#b"), summary(1)], [summary(1)]).warnings, "totals add up across processes"
  end

  def test_warns_about_project_files_coverage_never_saw
    map = build([{ "kind" => "boot", "cov" => {}, "unseen" => ["lib/early.rb"] }, rec("A#a", cov: RAN), summary(1)])
    assert_match "1 project file loaded before coverage started, so no test is linked to it and changing it runs every test: lib/early.rb", map.warnings.join
  end

  # Tests ran, but not one line of the project was seen (recorded from the wrong folder, say):
  # such a map would pick nothing for every change and look safe.
  def test_a_recording_that_saw_no_project_code_is_an_error
    error = assert_raises(Pitstop::Map::Error) { build([rec("A#a"), rec("A#b"), summary(2)]) }
    assert_match "2 tests were recorded, but none of them ran a file in this folder", error.message
  end

  def test_a_recording_error_or_no_tests_at_all_is_an_error
    error = assert_raises(Pitstop::Map::Error) { build([rec("A#a"), { "kind" => "error", "message" => "threads!" }]) }
    assert_equal "threads!", error.message
    assert_raises(Pitstop::Map::Error) { build([{ "kind" => "boot", "cov" => {} }]) }
  end

  def test_saves_and_loads_and_refuses_other_versions
    Dir.mktmpdir do |dir|
      path = File.join(dir, ".pitstop", "map.json.gz")
      build([rec("A#a", cov: { "lib/cart.rb" => [[5, 5]] }), summary(1)], dirty: ["lib/cart.rb"]).save(path)
      map = Pitstop::Map.load(path)
      assert_equal COMMIT, map.commit
      assert_equal ["lib/cart.rb"], map.dirty
      assert_equal "minitest", map.framework
      assert_equal %w[A#a], ids(map, "lib/cart.rb", 5..5)
      assert_equal [0], map.tests_in_file("test/cart_test.rb").to_a

      Zlib::GzipWriter.open(path) { _1.write(JSON.generate("version" => 99)) }
      assert_raises(Pitstop::Map::Error) { Pitstop::Map.load(path) }
    end
  end

  # --- files a test reads -------------------------------------------------------------------------

  def readers(map, path) = map.readers(path, onward: false).then { |found| found.all ? :all : found.tests.map { map.tests[_1].id }.sort }

  # A spec file's before(:context) hook reads a file once, for all its tests.
  def test_what_a_test_files_shared_setup_read_counts_for_all_its_tests
    map = build([rec("A#a", cov: { "lib/cart.rb" => [[5, 5]] }), rec("A#b"), rec("B#a", file: "test/b_test.rb"),
                 { "kind" => "between", "file" => "test/cart_test.rb", "cov" => {}, "reads" => ["docs/shared.md"] }, summary(3)])
    assert_equal %w[A#a A#b], readers(map, "docs/shared.md")
  end

  def test_what_a_program_started_by_a_test_read_counts_for_that_test
    map = build([rec("A#a", cov: { "lib/cart.rb" => [[5, 5]] }), rec("A#b"), summary(2)],
                [{ "kind" => "child", "test" => "A#b", "cov" => {}, "reads" => ["docs/a.md"] }])
    assert_equal %w[A#b], readers(map, "docs/a.md")
  end

  # Something read the file, and it can't be said for which test: while the app started, in a
  # freshly forked worker, or in a program started by a test that was never recorded.
  def test_a_read_no_test_can_be_linked_to_counts_for_every_test
    tests = [rec("A#a", cov: { "lib/cart.rb" => [[5, 5]] }), summary(1)]
    [{ "kind" => "boot", "cov" => {}, "reads" => ["docs/a.md"] },
     { "kind" => "worker_boot", "cov" => {}, "reads" => ["docs/a.md"] },
     { "kind" => "child", "test" => "Gone#test", "cov" => {}, "reads" => ["docs/a.md"] }].each do |record|
      assert_equal :all, readers(build(tests, [record]), "docs/a.md"), record["kind"]
    end
  end

  def test_the_tests_after_a_reader_are_those_of_its_own_process_in_the_order_they_ran
    map = build([rec("A#c"), rec("A#a", cov: { "lib/cart.rb" => [[5, 5]] }).merge("reads" => ["docs/a.md"]), rec("A#b"), summary(3)],
                [rec("B#a", file: "test/b_test.rb"), rec("B#b", file: "test/b_test.rb"), summary(2)])
    after = map.readers("docs/a.md", onward: true).tests.map { map.tests[_1].id }.sort
    assert_equal %w[A#a A#b], after
  end
end
