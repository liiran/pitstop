require "open3"

module Pitstop
  # The few git questions Pitstop asks, answered with plain git commands.
  #
  # Paths go in and come out relative to the project's folder, which is usually the top of the
  # repository but can be a folder inside it (`backend/` in a repository that also holds a
  # frontend). A file elsewhere in the repository comes out starting with `../`:
  #
  #   backend/app/models/cart.rb   →  app/models/cart.rb
  #   frontend/src/app.js          →  ../frontend/src/app.js
  class Git
    Change = Struct.new(:status, :path, :old_path, keyword_init: true) do
      def added? = status == "A"
      def deleted? = status == "D"
      def renamed? = status == "R"
    end

    class Error < StandardError; end

    # A full commit id, and nothing else: it's read from the map file and handed to git, where a
    # value starting with a dash would be read as an option.
    COMMIT = /\A\h{40}(\h{24})?\z/

    def initialize(root)
      @root = root
    end

    def head = run("rev-parse", "HEAD").strip

    def commit?(sha)
      return false unless COMMIT.match?(sha.to_s)

      system("git", "-C", @root, "cat-file", "-e", "#{sha}^{commit}", out: File::NULL, err: File::NULL)
    end

    # Paths with uncommitted changes (including untracked files).
    def dirty_paths
      fields = run("status", "--porcelain", "-z", "--untracked-files=all").split("\0")
      paths = []
      until fields.empty?
        entry = fields.shift
        paths << entry[3..]
        paths << fields.shift if entry.start_with?("R", "C") # a rename lists its old path next
      end
      paths.map { project_path(_1) }
    end

    # Everything that differs between `base` and the working tree, plus untracked files.
    def changes_since(base)
      check(base)
      fields = run("diff", "--name-status", "-z", "-M", base, "--").split("\0")
      changes = []
      until fields.empty?
        status = fields.shift
        if status.start_with?("R", "C")
          old_path = project_path(fields.shift)
          changes << Change.new(status: status[0], path: project_path(fields.shift), old_path:)
        else
          changes << Change.new(status: status[0], path: project_path(fields.shift))
        end
      end
      # `:/` is the whole repository, not only the folder git was started in.
      run("ls-files", "--others", "--exclude-standard", "--full-name", "-z", "--", ":/").split("\0").each do |path|
        changes << Change.new(status: "A", path: project_path(path))
      end
      changes
    end

    # A file's content at a commit, or nil if it didn't exist there.
    def show(sha, path)
      check(sha)
      # `<commit>:./path` and `<commit>:../path` are read from the folder git was started in.
      spec = path.start_with?("../") ? "#{sha}:#{path}" : "#{sha}:./#{path}"
      out, _, status = Open3.capture3("git", "-C", @root, "show", spec, "--", binmode: true)
      status.success? ? out.force_encoding(Encoding::UTF_8) : nil
    end

    # The project's folder inside the repository: "" at the top, "backend/" one level down.
    def prefix = @prefix ||= run("rev-parse", "--show-prefix").strip

    # A path from the top of the repository, as seen from the project's folder.
    def project_path(repo_path)
      return repo_path if prefix.empty?
      return repo_path.delete_prefix(prefix) if repo_path.start_with?(prefix)

      here = prefix.split("/")
      there = repo_path.split("/")
      while here.first && there.size > 1 && here.first == there.first
        here.shift
        there.shift
      end
      ("../" * here.size) + there.join("/")
    end

    private

    def check(sha)
      raise Error, "#{sha.inspect} isn't a commit id" unless COMMIT.match?(sha.to_s)
    end

    def run(*args)
      out, err, status = Open3.capture3("git", "-C", @root, *args)
      raise Error, "git #{args.first} failed: #{err.strip.lines.first.to_s.strip}" unless status.success?

      out
    end
  end
end
