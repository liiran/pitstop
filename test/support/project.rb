require "tmpdir"
require "fileutils"
require "open3"
require "json"
require "zlib"

# Throwaway projects for end-to-end tests: a real git repo with real test files, run through the
# real `pitstop` executable in a subprocess, the same way a user runs it.
module Fixture
  LIB = File.expand_path("../../lib", __dir__)
  EXE = File.expand_path("../../exe/pitstop", __dir__)

  # Extra gem versions for the framework matrix (Minitest 5 and 6, RSpec) live outside the
  # system gems, so other projects on this machine keep their versions:
  #   gem install --install-dir tmp/gems minitest:6.1.0 minitest:5.27.0 rspec activesupport
  # (PITSTOP_TEST_GEMS points somewhere else, as in Docker.) Only fixture subprocesses see them:
  # in this process they'd mix two Minitests.
  EXTRA_GEMS = ENV.fetch("PITSTOP_TEST_GEMS") { File.expand_path("../../tmp/gems", __dir__) }
  GEM_ENV = Dir.exist?(EXTRA_GEMS) ? { "GEM_PATH" => ([EXTRA_GEMS] + Gem.path).uniq.join(File::PATH_SEPARATOR) } : {}

  # The newest installed version of a gem with this major version, or nil.
  def self.latest(name, major)
    extra = Dir[File.join(EXTRA_GEMS, "specifications", "#{name}-[0-9]*.gemspec")].map do |path|
      Gem::Version.new(File.basename(path, ".gemspec").delete_prefix("#{name}-"))
    end
    (Gem::Specification.find_all_by_name(name).map(&:version) + extra).select { _1.segments.first == major }.max&.to_s
  end

  def self.minitest_versions = [5, 6].filter_map { latest("minitest", _1) }

  def self.rspec? = !latest("rspec-core", 3).nil?

  def self.fork? = Process.respond_to?(:fork)

  # Every environment variable a test process could inherit from a `pitstop` run that's running
  # these tests (when Pitstop records itself), cleared so fixtures start clean.
  # MT_NO_PLUGINS: with two Minitests installed side by side and no Bundler, Minitest's plugin
  # search would load the other version's files.
  CLEAN_ENV = %w[RUBYOPT RUBYLIB PITSTOP PITSTOP_TEST PITSTOP_OUT PITSTOP_ROOT PITSTOP_GRANULARITY PITSTOP_SELECTION
                 PITSTOP_KEEP_RUNS TEST].to_h { [_1, nil] }.merge(GEM_ENV, "MT_NO_PLUGINS" => "1").freeze

  # A binstub, as `bundle binstubs rspec-core` makes, so fixtures can run RSpec without Bundler.
  RSPEC_BIN = %(load Gem.bin_path("rspec-core", "rspec")\n)

  class Project
    attr_reader :dir

    def initialize(dir, files = {})
      @dir = dir
      git("init", "-q")
      git("config", "user.email", "test@example.com")
      git("config", "user.name", "Test")
      git("config", "core.autocrlf", "false")
      files.each { |path, content| write(path, content) }
    end

    def write(path, content)
      full = File.join(dir, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.binwrite(full, content)
    end

    def read(path) = File.binread(File.join(dir, path))

    def edit(path, from, to)
      source = read(path)
      raise ArgumentError, "#{path}: #{from.inspect} not found" unless source.include?(from)

      write(path, source.sub(from, to))
    end

    def delete(path) = FileUtils.rm_f(File.join(dir, path))

    def move(from, to)
      FileUtils.mkdir_p(File.dirname(File.join(dir, to)))
      git("mv", from, to)
    end

    def commit(message = "change")
      git("add", "-A")
      git("commit", "-q", "--allow-empty", "-m", message)
    end

    def git(*args)
      out, status = Open3.capture2e("git", "-C", dir, *args)
      raise "git #{args.join(' ')} failed: #{out}" unless status.success?

      out
    end

    # Runs `pitstop <argv>` here (or in the folder `at` inside the project, or with another copy
    # of Pitstop, `exe`). Returns [exit status, stdout, stderr].
    def pitstop(*argv, env: {}, at: ".", exe: EXE)
      out, err, status = Open3.capture3(CLEAN_ENV.merge(env), Gem.ruby, exe, *argv, chdir: File.join(dir, at))
      [status.exitstatus, out, err]
    end

    # `pitstop list --json`, parsed.
    def selection(env: {}, at: ".")
      code, out, err = pitstop("list", "--json", env:, at:)
      raise "pitstop list failed (#{code}): #{err}" unless code.zero?

      JSON.parse(out)
    end

    def map = Zlib::GzipReader.open(File.join(dir, ".pitstop", "map.json.gz")) { JSON.parse(_1.read) }
  end

  def self.project(files = {})
    Dir.mktmpdir("pitstop-fixture") do |dir|
      yield Project.new(File.realpath(dir), files)
    end
  end
end
