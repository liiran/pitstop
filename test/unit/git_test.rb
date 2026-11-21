require "minitest/autorun"
require_relative "../support/project"
require "pitstop/git"

class GitTest < Minitest::Test
  def changes(project, base)
    Pitstop::Git.new(project.dir).changes_since(base).map { [_1.status, _1.path, _1.old_path].compact }.sort
  end

  def test_every_kind_of_change_since_a_commit_including_uncommitted_ones
    Fixture.project("a.rb" => "a\n", "b.rb" => "b\n", "c.rb" => "c\n", "keep.rb" => "x\n" * 20) do |p|
      p.commit
      base = Pitstop::Git.new(p.dir).head
      p.write("a.rb", "a2\n")               # committed edit
      p.delete("b.rb")                      # committed delete
      p.move("keep.rb", "lib/kept.rb")      # committed rename
      p.commit
      p.write("c.rb", "c2\n")               # unstaged edit
      p.write("staged.rb", "s\n")
      p.git("add", "staged.rb")             # staged, never committed
      p.write("new dir/untracked.rb", "u\n") # untracked, with a space in the path
      p.write(".gitignore", "ignored.rb\n")
      p.write("ignored.rb", "i\n")          # ignored: not a change

      assert_equal [["A", ".gitignore"], ["A", "new dir/untracked.rb"], ["A", "staged.rb"], ["D", "b.rb"],
                    ["M", "a.rb"], ["M", "c.rb"], ["R", "lib/kept.rb", "keep.rb"]], changes(p, base)
    end
  end

  def test_dirty_paths_lists_uncommitted_files_and_both_sides_of_a_rename
    Fixture.project("a.rb" => "a\n", "old.rb" => "x\n" * 20) do |p|
      p.commit
      git = Pitstop::Git.new(p.dir)
      assert_empty git.dirty_paths
      p.write("a.rb", "a2\n")
      p.move("old.rb", "new.rb")
      p.write("fresh/x.rb", "x\n")
      assert_equal %w[a.rb fresh/x.rb new.rb old.rb], git.dirty_paths.sort
    end
  end

  def test_file_contents_at_a_commit
    Fixture.project("a.rb" => "one\n") do |p|
      p.commit
      git = Pitstop::Git.new(p.dir)
      sha = git.head
      p.write("a.rb", "two\n")
      p.commit
      assert_equal "one\n", git.show(sha, "a.rb")
      assert_nil git.show(sha, "missing.rb")
      assert git.commit?(sha)
      refute git.commit?("0" * 40)
    end
  end

  def test_outside_a_repo_is_a_clear_error
    Dir.mktmpdir do |dir|
      error = assert_raises(Pitstop::Git::Error) { Pitstop::Git.new(dir).head }
      assert_match "git rev-parse failed", error.message
    end
  end
end
