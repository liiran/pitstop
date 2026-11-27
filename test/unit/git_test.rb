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

  # A project one folder down has its installed gems one folder down too.
  def test_untracked_installed_gems_are_left_out_at_any_depth
    Fixture.project("apps/shop/lib/cart.rb" => "one\n", "apps/shop/vendor/bundle/kept.rb" => "x\n") do |p|
      p.commit
      base = Pitstop::Git.new(p.dir).head
      shop = Pitstop::Git.new(File.join(p.dir, "apps/shop"))
      p.write("apps/shop/vendor/bundle/ruby/3.4.0/gems/money-1.0/lib/money.rb", "x\n")
      p.write("apps/shop/.bundle/config", "x\n")
      p.write("apps/web/vendor/bundle/ruby/3.4.0/gems/money-1.0/lib/money.rb", "x\n")
      p.write("apps/shop/vendor/plugins/tax.rb", "x\n") # not where Bundler installs: still a change
      p.write("apps/shop/vendor/bundle/kept.rb", "y\n") # tracked: still a change
      expected = %w[vendor/bundle/kept.rb vendor/plugins/tax.rb]
      assert_equal expected, shop.dirty_paths.sort
      assert_equal expected, shop.changes_since(base).map(&:path).sort
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

  # A project in a folder of the repository sees its own files by their path inside the project,
  # and the rest of the repository through "../".
  def test_a_project_in_a_folder_of_the_repository
    files = { "apps/shop/lib/cart.rb" => "one\n", "apps/web/app.js" => "x\n", "README.md" => "x\n", "apps/shop/old.rb" => "x\n" * 20 }
    Fixture.project(files) do |p|
      p.commit
      git = Pitstop::Git.new(File.join(p.dir, "apps/shop"))
      base = git.head
      p.write("apps/shop/lib/cart.rb", "two\n")
      p.write("apps/web/app.js", "y\n")
      p.write("README.md", "y\n")
      p.move("apps/shop/old.rb", "libs/moved.rb")
      p.write("apps/shop/new file.rb", "n\n")
      p.write("apps/web/untracked.js", "n\n")

      found = git.changes_since(base).map { [_1.status, _1.path, _1.old_path].compact }.sort
      assert_equal [["A", "../web/untracked.js"], ["A", "new file.rb"], ["M", "../../README.md"], ["M", "../web/app.js"],
                    ["M", "lib/cart.rb"], ["R", "../../libs/moved.rb", "old.rb"]], found
      assert_equal %w[../../README.md ../../libs/moved.rb ../web/app.js ../web/untracked.js lib/cart.rb new\ file.rb old.rb],
                   git.dirty_paths.sort
      assert_equal "one\n", git.show(base, "lib/cart.rb")
      assert_equal "x\n", git.show(base, "../web/app.js")
      assert_nil git.show(base, "../web/missing.js")
    end
  end

  # The commit to compare with comes from the map file. Anything but a full commit id is refused
  # before git sees it: git would read a value like "--output=file" as an option.
  # "Was this method name already written somewhere in the project?", asked of the files as they
  # were at a commit, whole words only.
  def test_whether_a_name_appears_anywhere_at_a_commit
    Fixture.project("lib/cart.rb" => "def discount_rate\n  items.sum\nend\n", "app/views/cart.erb" => "<%= cart.full? %>\n") do |p|
      p.commit
      git = Pitstop::Git.new(p.dir)
      at = git.head
      p.write("lib/later.rb", "def added_later = 1\n") # not in that commit
      assert git.mentioned?(at, "discount_rate")
      assert git.mentioned?(at, "full?"), "a name ending in ? or ! or = is looked up without it"
      assert git.mentioned?(at, "sum")
      refute git.mentioned?(at, "discount"), "part of a longer name isn't a mention"
      refute git.mentioned?(at, "added_later")
      refute git.mentioned?(at, "nowhere_at_all")
      assert git.mentioned?(at, "=="), "an operator can't be looked up as a word, and Ruby has them all: yes"
      assert_raises(Pitstop::Git::Error) { git.mentioned?("--output=x", "sum") }
    end
  end

  def test_only_a_full_commit_id_reaches_git
    Fixture.project("a.rb" => "a\n") do |p|
      p.commit
      git = Pitstop::Git.new(p.dir)
      marker = File.join(p.dir, "made-by-git.txt")
      ["--output=#{marker}", "-h", "HEAD", "main", "abc123", "", nil, "#{git.head} --output=#{marker}"].each do |value|
        refute git.commit?(value), value.inspect
        assert_raises(Pitstop::Git::Error) { git.changes_since(value) }
        assert_raises(Pitstop::Git::Error) { git.show(value, "a.rb") }
      end
      refute File.exist?(marker)
    end
  end

  def test_outside_a_repo_is_a_clear_error
    Dir.mktmpdir do |dir|
      error = assert_raises(Pitstop::Git::Error) { Pitstop::Git.new(dir).head }
      assert_match "git rev-parse failed", error.message
    end
  end
end
