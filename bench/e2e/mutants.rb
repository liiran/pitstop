# Plants small bugs, one at a time, in code the tests run, and checks that Pitstop's selection
# catches every one the whole suite catches.
#
#   ruby bench/e2e/mutants.rb <app dir> <results.jsonl> <how many> [-- test command]
#
# For each planted bug:
#   1. `pitstop run`. If it fails, the selection caught the bug.
#   2. If it passes, the whole suite runs. If that passes too, no test catches this bug, and it
#      says nothing about Pitstop. If the whole suite fails (twice, to rule out a flaky test),
#      Pitstop missed a failing test.
#
# The bugs are the usual small ones: == for !=, > for >=, && for ||, true for false, if for
# unless, present? for blank?. Each goes in a different method, on a line some test ran when the
# map was made, picked at random with a fixed seed so the same list comes out every time.
#
# Environment:
#   PLAIN_COMMAND  the whole suite without Pitstop (required)
#   SOURCES        where to plant bugs (default "app/**/*.rb,lib/**/*.rb")
#   SEED           picks the bugs (default 1)
require "prism"
require_relative "bench"

app, out_path, count, *rest = ARGV
command = rest.first == "--" ? rest.drop(1) : []
tail = command.empty? ? [] : ["--", *command]
plain = ENV.fetch("PLAIN_COMMAND").split
Dir.chdir(app)

# Places in a file where one small edit plants a bug: [byte offset, length, replacement, line, method, what].
class Sites < Prism::Visitor
  CALLS = { "==" => "!=", "!=" => "==", ">" => ">=", ">=" => ">", "<" => "<=", "<=" => "<",
            "present?" => "blank?", "blank?" => "present?", "any?" => "none?", "none?" => "any?" }.freeze
  WORDS = { "&&" => "||", "||" => "&&", "and" => "or", "or" => "and", "if" => "unless", "unless" => "if" }.freeze

  attr_reader :found

  def initialize
    super
    @found = []
    @method = nil
  end

  def visit_def_node(node)
    outer, @method = @method, node.name.to_s
    super
  ensure
    @method = outer
  end

  def visit_call_node(node)
    swap(node.message_loc, CALLS[node.name.to_s]) if node.message_loc && CALLS.key?(node.name.to_s) && node.message_loc.slice == node.name.to_s
    super
  end

  def visit_and_node(node) = word(node.operator_loc) || super

  def visit_or_node(node) = word(node.operator_loc) || super

  def visit_true_node(node) = swap(node.location, "false") || super

  def visit_false_node(node) = swap(node.location, "true") || super

  def visit_if_node(node)
    word(node.if_keyword_loc) if node.if_keyword_loc && node.if_keyword_loc.slice == "if" && !node.subsequent.is_a?(Prism::IfNode)
    super
  end

  def visit_unless_node(node)
    word(node.keyword_loc)
    super
  end

  private

  def word(loc) = swap(loc, WORDS[loc.slice])

  def swap(loc, to)
    @found << [loc.start_offset, loc.length, to, loc.start_line, @method, "#{loc.slice} → #{to}"] if @method && to
    nil
  end
end

_, code, seconds = Bench.sh(*Bench::PITSTOP, "record", *tail)
abort "record failed" unless File.exist?(".pitstop/map.json.gz")
map = Bench.map
baseline = map["tests"].count { _1[3] == "fail" }
puts "recorded #{map['tests'].size} tests in #{seconds}s (exit #{code}); already failing: #{baseline}"

# Lines some test ran, per file.
ran = map["files"].transform_values { |entries| entries.flat_map(&:first) }
covered = ->(path, line) { ran.fetch(path, []).any? { |first, last| line.between?(first, last) } }

sites = ENV.fetch("SOURCES", "app/**/*.rb,lib/**/*.rb").split(",").flat_map { Dir[_1] }.sort.flat_map do |path|
  source = File.binread(path)
  parsed = Prism.parse(source)
  next [] unless parsed.success?

  finder = Sites.new
  parsed.value.accept(finder)
  finder.found.select { |_, _, _, line,| covered.(path, line) }.filter_map do |offset, length, to, line, method, what|
    changed = source.dup
    changed[offset, length] = to
    { path:, line:, method:, what:, source:, changed: } if Prism.parse(changed).success?
  end
end
random = Random.new(Integer(ENV.fetch("SEED", "1")))
chosen = sites.group_by { [_1[:path], _1[:method]] }.values.map { _1.sample(random:) }.shuffle(random:).first(Integer(count))
puts "#{sites.size} places to plant a bug in #{sites.map { _1[:path] }.uniq.size} files; trying #{chosen.size}"

failed = ->(output, exit_code) { exit_code != 0 && (baseline.zero? || output.scan(/(\d+) (?:failures|errors)/).flatten.sum(&:to_i) > baseline || Bench.framework_ran(output).zero?) }
names = ->(output) { (output.scan(/^([A-Z][\w:]*#test_\S+)/).flatten + output.scan(%r{^rspec (\./\S+)}).flatten).uniq.first(20) }
done = File.exist?(out_path) ? File.readlines(out_path).map { JSON.parse(_1).values_at("path", "line", "what") } : []

chosen.each do |site|
  next if done.include?(site.values_at(:path, :line, :what))

  row = site.slice(:path, :line, :method, :what)
  File.binwrite(site[:path], site[:changed])
  begin
    listed, = Bench.sh(*Bench::PITSTOP, "list", "--json")
    json = Bench.selection(listed)
    row[:picked] = json["run_all"] ? "all" : Bench.selected_ids(json, map).size
    out, code, row[:run_s] = Bench.sh(*Bench::PITSTOP, "run", *tail)
    row[:run_exit] = code
    if failed.(out, code)
      row[:caught_by] = "selection"
    else
      full, full_code, = Bench.sh(*plain)
      if failed.(full, full_code)
        again, again_code, = Bench.sh(*plain)
        row[:caught_by] = failed.(again, again_code) ? "whole suite only" : "nothing (a flaky failure)"
        row[:failing] = names.(full) & names.(again) if row[:caught_by] == "whole suite only"
      else
        row[:caught_by] = "nothing"
      end
    end
  ensure
    File.binwrite(site[:path], site[:source])
  end
  File.write(out_path, JSON.generate(row) + "\n", mode: "a")
  puts "#{row[:path]}:#{row[:line]} #{row[:method]} (#{row[:what]}): picked #{row[:picked]}, caught by #{row[:caught_by]}#{" #{row[:failing].inspect}" if row[:failing]}"
end

rows = File.readlines(out_path).map { JSON.parse(_1) }
catchable = rows.reject { _1["caught_by"].start_with?("nothing") }
puts "\n#{rows.size} planted bugs: #{catchable.size} caught by the whole suite, " \
     "#{catchable.count { _1['caught_by'] == 'selection' }} of those by Pitstop's selection, " \
     "#{rows.size - catchable.size} caught by no test"
