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
# WHERE=outside plants them outside methods instead, in code that runs when a file loads: a
# constant's number, text or true/false is changed, a setting such as `presence: true` is flipped,
# or a line such as `validates :name, presence: true` or `include Comparable` is taken out. A test can
# depend on that code without running a line of the file, which is what makes it the hard case.
#
# Environment:
#   PLAIN_COMMAND  the whole suite without Pitstop (required)
#   SOURCES        where to plant bugs (default "app/**/*.rb,lib/**/*.rb")
#   SEED           picks the bugs (default 1)
#   WHERE          inside (methods, the default) or outside (code that runs when a file loads)
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

# Places outside methods: the statements written directly in a class or module body.
# Same shape as Sites#found, with the constant or call's name where the method's name goes.
def outside_sites(root)
  found = []
  flip = lambda do |node, name|
    case node
    when Prism::TrueNode then found << [node.location.start_offset, node.location.length, "false", node.location.start_line, name, "#{name}: true → false"]
    when Prism::FalseNode then found << [node.location.start_offset, node.location.length, "true", node.location.start_line, name, "#{name}: false → true"]
    when Prism::IntegerNode
      found << [node.location.start_offset, node.location.length, (node.value + 1).to_s, node.location.start_line, name, "#{name}: #{node.value} → #{node.value + 1}"]
    when Prism::StringNode
      found << [node.location.start_offset, node.location.length, "(#{node.slice}).swapcase", node.location.start_line, name, "#{name}: its text changed"]
    else return false
    end
    true
  end
  statement = lambda do |node|
    case node
    when Prism::ConstantWriteNode then flip.(node.value, node.name.to_s)
    when Prism::CallNode
      next if node.receiver || node.block.is_a?(Prism::BlockNode)

      name = node.name.to_s
      settings = node.arguments&.arguments.to_a.grep(Prism::KeywordHashNode).flat_map(&:elements).grep(Prism::AssocNode)
      next if settings.any? { flip.(_1.value, "#{name} #{_1.key.slice.delete_suffix(':')}") }

      loc = node.location
      found << [loc.start_offset, loc.length, "nil", loc.start_line, name, "#{node.slice.lines.first.strip[0, 60]} taken out"]
    end
  end
  walk = lambda do |node|
    case node
    when Prism::ClassNode, Prism::ModuleNode
      node.body.body.each { statement.(_1) } if node.body.is_a?(Prism::StatementsNode)
      node.body&.compact_child_nodes&.each { walk.(_1) }
    when Prism::DefNode then nil
    else node.compact_child_nodes.each { walk.(_1) }
    end
  end
  walk.(root)
  found
end

outside = ENV["WHERE"] == "outside"
_, code, seconds = Bench.sh(*Bench::PITSTOP, "record", *tail)
abort "record failed" unless File.exist?(".pitstop/map.json.gz")
map = Bench.map
baseline = map["tests"].count { _1[3] == "fail" }
puts "recorded #{map['tests'].size} tests in #{seconds}s (exit #{code}); already failing: #{baseline}"

# Lines some test ran, per file. Code outside methods runs when the file loads, which for most
# files is before the first test, so there it is the lines run by then that count.
ran = map["files"].transform_values { |entries| entries.flat_map(&:first) }
ran = map["boot"].merge(ran) { |_, before, during| before + during } if outside
covered = ->(path, line) { ran.fetch(path, []).any? { |first, last| line.between?(first, last) } }

sites = ENV.fetch("SOURCES", "app/**/*.rb,lib/**/*.rb").split(",").flat_map { Dir[_1] }.sort.flat_map do |path|
  source = File.binread(path)
  parsed = Prism.parse(source)
  next [] unless parsed.success?

  found = if outside then outside_sites(parsed.value)
          else Sites.new.tap { parsed.value.accept(_1) }.found
          end
  found.select { |_, _, _, line,| covered.(path, line) }.filter_map do |offset, length, to, line, method, what|
    changed = source.dup
    changed[offset, length] = to
    { path:, line:, method:, what:, source:, changed: } if Prism.parse(changed).success?
  end
end
random = Random.new(Integer(ENV.fetch("SEED", "1")))
# One bug per method, or outside methods one per file, so a few big files don't take them all.
chosen = sites.group_by { outside ? _1[:path] : [_1[:path], _1[:method]] }.values.map { _1.sample(random:) }.shuffle(random:).first(Integer(count))
puts "#{sites.size} places to plant a bug in #{sites.map { _1[:path] }.uniq.size} files; trying #{chosen.size}"

failed = ->(output, exit_code) { exit_code != 0 && (baseline.zero? || output.scan(/(\d+) (?:failures|errors)/).flatten.sum(&:to_i) > baseline || Bench.framework_ran(output).zero?) }
# The tests a run's output says failed, by the names the map knows them under. Rails and RSpec
# print a line to run each failure again ("bin/rails test test/cart_test.rb:12",
# "rspec ./spec/cart_spec.rb:12"); Minitest and its reporters name the test ("CartTest#test_total").
known = map["tests"].map(&:first).to_set
places = map["tests"].to_h { [[_1[1], _1[2]], _1[0]] }
failing = lambda do |output|
  found = output.scan(%r{^(?:bin/rails test|rspec) (?:\./)?([^\s:\[]+):(\d+)}).filter_map { |file, line| places[[file, line.to_i]] }
  found += output.scan(%r{^rspec (\./\S+\[[\d:]+\])}).flatten
  found += output.scan(/[A-Z][\w:]*#test_\S+/).map { _1.delete_suffix(":") }
  found.uniq.select { known.include?(_1) }
end
done = File.exist?(out_path) ? File.readlines(out_path).map { JSON.parse(_1).values_at("path", "line", "what") } : []

chosen.each do |site|
  next if done.include?(site.values_at(:path, :line, :what))

  row = site.slice(:path, :line, :method, :what)
  File.binwrite(site[:path], site[:changed])
  begin
    listed, = Bench.sh(*Bench::PITSTOP, "list", "--json")
    json = Bench.selection(listed)
    picked = json["run_all"] ? nil : Bench.selected_ids(json, map).to_set
    row[:picked] = picked ? picked.size : "all"
    out, code, row[:run_s] = Bench.sh(*Bench::PITSTOP, "run", *tail)
    row[:run_exit] = code
    caught = failed.(out, code)

    # The whole suite, every time: it says which tests the bug breaks, and each of those has to be
    # among the picked ones. A run that fails because of one picked test, while another failing
    # test was left out, is not good enough.
    full, full_code, = Bench.sh(*plain)
    broken = failed.(full, full_code)
    left_out = picked ? failing.(full).reject { picked.include?(_1) } : []
    if broken && (!caught || left_out.any?)
      again, again_code, = Bench.sh(*plain) # once more, to rule out a test that fails now and then
      broken = failed.(again, again_code)
      left_out &= failing.(again)
    end
    row[:failing] = broken ? failing.(full).size : 0
    row[:left_out] = broken ? left_out.first(20) : []
    row[:caught_by] = if !broken then failed.(full, full_code) ? "nothing (a flaky failure)" : "nothing"
                      elsif !caught then "whole suite only"
                      elsif left_out.any? then "selection, but not every failing test"
                      else "selection"
                      end
  ensure
    File.binwrite(site[:path], site[:source])
  end
  File.write(out_path, JSON.generate(row) + "\n", mode: "a")
  puts "#{row[:path]}:#{row[:line]} #{row[:method]} (#{row[:what]}): picked #{row[:picked]}, #{row[:failing]} failing, " \
       "caught by #{row[:caught_by]}#{" #{row[:left_out].inspect}" unless row[:left_out].empty?}"
end

rows = File.readlines(out_path).map { JSON.parse(_1) }
catchable = rows.reject { _1["caught_by"].start_with?("nothing") }
puts "\n#{rows.size} planted bugs: #{catchable.size} caught by the whole suite, " \
     "#{catchable.count { _1['caught_by'] == 'selection' }} of those by Pitstop's selection with every failing test picked, " \
     "#{rows.size - catchable.size} caught by no test. " \
     "#{catchable.sum { _1['failing'].to_i }} failing tests in all, #{catchable.sum { _1['left_out'].to_a.size }} of them left out."
