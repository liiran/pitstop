# Shared by check.rb, replay.rb and mutants.rb: timing a command, reading a map, describing the
# machine.
require "json"
require "open3"
require "zlib"
require "set"
require "etc"
require "time"
require "tempfile"
require "timeout"
require "pty"
require "io/console"
require "io/wait"

$stdout.sync = true # progress shows as it happens, also when the output goes to a file

module Bench
  PITSTOP_DIR = File.expand_path("../..", __dir__)
  PITSTOP = [Gem.ruby, File.join(PITSTOP_DIR, "exe", "pitstop")].freeze
  # A run that takes longer than this is stopped and counted as failed (exit status 124).
  LIMIT = Float(ENV.fetch("LIMIT", "3600"))
  TERMINAL = ENV["TERMINAL"] != "0"
  # Colour codes and cursor moves, which a terminal gets and a file doesn't.
  ESCAPES = /\e\[[0-9;?]*[ -\/]*[@-~]/

  module_function

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # A command's output, exit status and wall-clock seconds: what someone waiting for it sees,
  # from starting the process to its exit.
  #
  # The command runs with a terminal attached, the way a developer runs it. That matters: a
  # progress bar can behave very differently when its output goes to a file instead (Fizzy's
  # makes its whole suite take 54 s to a file and 20 s in a terminal, on the same machine).
  # TERMINAL=0 runs commands with their output going to a file, as a CI job does.
  def sh(*command) = TERMINAL ? in_terminal(*command) : to_file(*command)

  def in_terminal(*command)
    out = +""
    started = now
    code = nil
    PTY.spawn(*command) do |reader, _writer, pid|
      reader.winsize = [40, 120]
      begin
        loop do
          if reader.wait_readable(5) then out << reader.readpartial(65_536)
          elsif now - started > LIMIT
            Process.kill("KILL", -pid)
            code = 124
            break
          end
        end
      rescue EOFError, Errno::EIO
        nil # the command finished and closed the terminal
      end
      Process.wait(pid)
      code ||= $?.exitstatus
    end
    seconds = (now - started).round(2)
    # A line redrawn in place (a progress bar) becomes lines of its own.
    [out.force_encoding(Encoding::UTF_8).scrub("?").gsub(ESCAPES, "").gsub(/\r\n?/, "\n"), code, seconds]
  end

  def to_file(*command)
    out = Tempfile.new("bench")
    started = now
    pid = Process.spawn(*command, out: out.path, err: %i[child out], pgroup: true)
    code = begin
      Timeout.timeout(LIMIT) { Process.wait(pid) }
      $?.exitstatus
    rescue Timeout::Error
      Process.kill("KILL", -pid)
      Process.wait(pid)
      124
    end
    seconds = (now - started).round(2)
    [File.binread(out.path).force_encoding(Encoding::UTF_8).scrub("?"), code, seconds]
  ensure
    out&.close!
  end

  def median(numbers)
    sorted = numbers.compact.sort
    return nil if sorted.empty?

    mid = sorted.size / 2
    sorted.size.odd? ? sorted[mid] : ((sorted[mid - 1] + sorted[mid]) / 2.0).round(2)
  end

  def map(path = ".pitstop/map.json.gz") = Zlib::GzipReader.open(path) { JSON.parse(_1.read) }

  def git(*args, dir: ".")
    out, status = Open3.capture2("git", "-C", dir, *args)
    raise "git #{args.join(' ')} failed" unless status.success?

    out.strip
  end

  # Where the numbers were measured, saved with them.
  def machine
    cpu = File.read("/proc/cpuinfo")[/^model name\s*:\s*(.+)$/, 1] if File.exist?("/proc/cpuinfo")
    { cpu:, cores: Etc.nprocessors, ruby: RUBY_DESCRIPTION, terminal: TERMINAL,
      pitstop: "#{git('rev-parse', '--short', 'HEAD', dir: PITSTOP_DIR)}#{'+changes' unless git('status', '--porcelain', dir: PITSTOP_DIR).empty?}" }
  end

  # How busy the machine is (runnable processes averaged over the last minute), so a noisy run
  # can be told from a quiet one.
  def load_average = File.exist?("/proc/loadavg") ? File.read("/proc/loadavg").split.first.to_f : nil

  # What `pitstop list --json` printed.
  def selection(output) = JSON.parse(output[/^\{.*\}/m])

  # The tests a selection names, as ids: its tests, plus the map's tests in its whole test files.
  def selected_ids(json, map)
    return map["tests"].map(&:first) if json["run_all"]

    (json["tests"] + map["tests"].select { json["files"].include?(_1[1]) }.map(&:first)).uniq
  end

  # A selection's share of the suite's own test time, from the times in the map (taken while
  # recording, so slower than a plain run, but slowed the same way for every test).
  def share_of_test_time(ids, map)
    ms = map["tests"].to_h { [_1[0], _1[4].to_f] }
    total = ms.values.sum
    total.zero? ? 0.0 : (100 * ids.sum { ms.fetch(_1, 0) } / total).round(1)
  end

  # How many tests the framework says it ran, summed over every summary line in the output.
  def framework_ran(output) = output.scan(/^(\d+) (?:runs|tests|examples),/).flatten.sum(&:to_i)

  # How many tests `pitstop run` counted: selected tests that ran, plus those from whole files.
  def pitstop_ran(output)
    line = output[/^Pitstop: ran .*$/] or return nil
    line[/ran (\d+) of/, 1].to_i + line[/plus (\d+) from/, 1].to_i
  end
end
