# Recording time of several versions of Pitstop next to a plain run, taking turns, to see what a
# change to the recorder costs on the same machine in the same session.
#
#   mkdir -p /ab/<commit> && git archive <commit> lib exe | tar -x -C /ab/<commit>    for each version
#   PLAIN_COMMAND="bin/rails test" VERSIONS=e5fed82,1bb4b2e,HEAD ruby bench/e2e/recorders.rb [results.json]
#
# Run it in the project's folder, set up as the other scripts do it. ROUNDS (default 4) is how
# many times each is timed; AB (default /ab) is where the versions are.
require "json"
require_relative "bench"

versions = ENV.fetch("VERSIONS").split(",")
folder = ENV.fetch("AB", "/ab")
times = Hash.new { |h, k| h[k] = [] }
Integer(ENV.fetch("ROUNDS", "4")).times do |round|
  (["plain"] + versions).rotate(round).each do |name|
    command = name == "plain" ? ENV.fetch("PLAIN_COMMAND").split : [Gem.ruby, File.join(folder, name, "exe", "pitstop"), "record"]
    _, code, seconds = Bench.sh(*command)
    times[name] << seconds
    puts "round #{round + 1} #{name}: #{seconds}s (exit #{code})"
  end
end
times.each { |name, list| puts "#{name.ljust(8)} #{list.inspect}: best #{list.min}s, #{(list.min / times['plain'].min).round(2)} times the best plain run" }
File.write(ARGV[0], JSON.pretty_generate(machine: Bench.machine, seconds: times) + "\n", mode: "wb") if ARGV[0]
