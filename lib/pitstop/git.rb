require "open3"

module Pitstop
  # The few git questions Pitstop asks, answered with plain git commands.
  class Git
    Change = Struct.new(:status, :path, :old_path, keyword_init: true) do
      def added? = status == "A"
      def deleted? = status == "D"
      def renamed? = status == "R"
    end

    class Error < StandardError; end

    def initialize(root)
      @root = root
    end

    def head = run("rev-parse", "HEAD").strip

    def commit?(sha) = system("git", "-C", @root, "cat-file", "-e", "#{sha}^{commit}", out: File::NULL, err: File::NULL)

    # Paths with uncommitted changes (including untracked files), relative to the repo root.
    def dirty_paths
      fields = run("status", "--porcelain", "-z", "--untracked-files=all").split("\0")
      paths = []
      until fields.empty?
        entry = fields.shift
        paths << entry[3..]
        paths << fields.shift if entry.start_with?("R", "C") # a rename lists its old path next
      end
      paths
    end

    # Everything that differs between `base` and the working tree, plus untracked files.
    def changes_since(base)
      fields = run("diff", "--name-status", "-z", "-M", base).split("\0")
      changes = []
      until fields.empty?
        status = fields.shift
        if status.start_with?("R", "C")
          old_path = fields.shift
          changes << Change.new(status: status[0], path: fields.shift, old_path:)
        else
          changes << Change.new(status: status[0], path: fields.shift)
        end
      end
      run("ls-files", "--others", "--exclude-standard", "-z").split("\0").each do |path|
        changes << Change.new(status: "A", path:)
      end
      changes
    end

    # A file's content at a commit, or nil if it didn't exist there.
    def show(sha, path)
      out, status = Open3.capture2("git", "-C", @root, "show", "#{sha}:#{path}", binmode: true)
      status.success? ? out.force_encoding(Encoding::UTF_8) : nil
    end

    private

    def run(*args)
      out, err, status = Open3.capture3("git", "-C", @root, *args)
      raise Error, "git #{args.first} failed: #{err.strip}" unless status.success?

      out
    end
  end
end
