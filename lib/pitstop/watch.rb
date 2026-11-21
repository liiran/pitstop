# Shared by the two files Pitstop loads into a test process through RUBYOPT: the recorder
# (`pitstop record`) and the filter (`pitstop run`). Both load before the app and its gems, so
# this file requires nothing.
module Pitstop
  module Watch
    MODULE_NAME = Module.instance_method(:name)

    # Calls `minitest` the moment Minitest::Test is defined and `rspec` (with the runner class) the
    # moment RSpec's runner is. Watching class definitions, rather than wrapping Kernel#require,
    # keeps out of the way of Bootsnap, Zeitwerk and Ruby's bundled-gems shim, which all rename
    # `require` and would loop through a wrapper.
    def self.frameworks(minitest:, rspec:)
      TracePoint.new(:class) do |tp|
        # Module#name itself: some classes redefine `name` (or `self.name`) as a DSL.
        case MODULE_NAME.bind_call(tp.self)
        when "Minitest::Test" then minitest.call
        when "RSpec::Core::Runner" then rspec.call(tp.self)
        end
      end.tap(&:enable)
    end

    # The file a Minitest test belongs to: the file that defines its class (so tests mixed in from
    # a module still belong to the test file that runs them), or else the test method's file.
    def self.minitest_file(klass, method_name)
      name = MODULE_NAME.bind_call(klass)
      class_file = begin
        Object.const_source_location(name)&.first if name&.match?(/\A[A-Z]\w*(::[A-Z]\w*)*\z/)
      rescue NameError
        nil
      end
      return class_file if class_file && !class_file.empty?

      klass.instance_method(method_name).source_location&.first
    rescue NameError
      nil
    end

    def self.minitest_line(klass, method_name)
      klass.instance_method(method_name).source_location&.last
    rescue NameError
      nil
    end

    # RSpec's file for an example or group: for a shared example, the spec file that includes it.
    def self.rspec_file(metadata) = File.expand_path(metadata[:rerun_file_path] || metadata[:file_path])
  end
end
