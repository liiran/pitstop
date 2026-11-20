# Spike D: plant one bug at a time, run the whole suite to see which tests catch it, and check
# that Pitstop's selection contains every one of them.
#   ruby mutants.rb <app dir> <mutants file> <test command...>
require "json"
require "open3"
require "set"

app, list, *command = ARGV
Dir.chdir(app)
mutants = File.readlines(list, chomp: true).reject { _1.empty? || _1.start_with?("#") }.map { _1.split(" | ") }

def failures(output)
  output.scan(/^([A-Z][\w:]*#test_\w+)(?: \[|:$)/).flatten.to_set |
    output.scan(%r{^rspec (\./\S+)}).flatten.to_set
end

results = mutants.map do |path, from, to|
  source = File.read(path)
  abort "#{path}: '#{from}' not found" unless source.include?(from)
  File.write(path, source.sub(from, to))
  begin
    picked = JSON.parse(`#{Gem.ruby} /pitstop/exe/pitstop list --json`)
    out, = Open3.capture2e(*command)
    caught_by = failures(out)
    # RSpec failures name "./spec/x_spec.rb:12" and selections "./spec/x_spec.rb[1:2]": compare files.
    file_of = ->(t) { t.start_with?("./") ? t.delete_prefix("./").sub(/[\[:].*\z/, "") : t }
    selected = (picked["tests"] + picked["files"]).map(&file_of).to_set
    missed = caught_by.reject { |t| selected.include?(file_of.(t)) }
    row = { mutant: "#{path}: #{from} → #{to}", caught_by: caught_by.size, selected: picked["tests"].size,
            run_all: picked["run_all"], missed: missed.to_a }
    puts JSON.generate(row)
    row
  ensure
    File.write(path, source)
  end
end

caught = results.count { _1[:caught_by].positive? }
safe = results.count { _1[:caught_by].positive? && _1[:missed].empty? }
puts "\n#{results.size} planted bugs, #{caught} caught by the full suite, #{safe} of those caught by Pitstop's selection"
