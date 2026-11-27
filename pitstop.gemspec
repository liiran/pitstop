require_relative "lib/pitstop/version"

Gem::Specification.new do |spec|
  spec.name = "pitstop"
  spec.version = Pitstop::VERSION
  spec.summary = "Runs only the tests your change can affect"
  spec.description = "Records which code each test runs, then runs only the tests a change can affect. Works with Minitest and RSpec."
  spec.authors = ["Liran"]
  spec.homepage = "https://github.com/liiran/pitstop"
  spec.required_ruby_version = ">= 3.2"
  spec.files = Dir["lib/**/*.rb", "exe/pitstop", "README.md", "SECURITY.md"]
  spec.bindir = "exe"
  spec.executables = ["pitstop"]
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"

  spec.add_dependency "prism", "~> 1.2"
end
