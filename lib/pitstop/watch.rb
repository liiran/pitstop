# Shared by the two files Pitstop loads into a test process through RUBYOPT: the recorder
# (`pitstop record`) and the filter (`pitstop run`). Both load before the app and its gems, so
# this file requires nothing.
module Pitstop
  module Watch
    MODULE_NAME = Module.instance_method(:name)

    # Calls `minitest` the moment Minitest::Test is defined, `rspec` (with the runner class) the
    # moment RSpec's runner is, and `simplecov` (with the module) when SimpleCov is. Watching class
    # definitions, rather than wrapping Kernel#require, keeps out of the way of Bootsnap, Zeitwerk
    # and Ruby's bundled-gems shim, which all rename `require` and would loop through a wrapper.
    def self.frameworks(minitest: nil, rspec: nil, simplecov: nil)
      TracePoint.new(:class) do |tp|
        # Module#name itself: some classes redefine `name` (or `self.name`) as a DSL.
        case MODULE_NAME.bind_call(tp.self)
        when "Minitest::Test" then minitest&.call
        when "RSpec::Core::Runner" then rspec&.call(tp.self)
        when "SimpleCov" then simplecov&.call(tp.self)
        end
      end.tap(&:enable)
    end

    # Test names and file names go into line-per-entry, tab-separated files (the selection, and
    # the list of tests that ran). A name can hold a newline or a tab (`define_method("test a\nb")`),
    # so those are written as \n and \t, and a backslash as \\.
    ESCAPED = { "\\" => "\\\\", "\n" => "\\n", "\t" => "\\t", "\r" => "\\r" }.freeze
    UNESCAPED = ESCAPED.invert.freeze

    def self.escape(text) = text.to_s.scrub("?").gsub(/[\\\n\t\r]/, ESCAPED)

    def self.unescape(text) = text.gsub(/\\[\\ntr]/, UNESCAPED)

    # A Minitest test's name in the map: "CartTest#test_total". A name has to be valid text to be
    # written down, and free of NUL bytes to be passed to a subprocess in its environment.
    def self.minitest_id(klass, method_name)
      "#{MODULE_NAME.bind_call(klass)}##{method_name}".force_encoding(Encoding::UTF_8).scrub("?").delete("\0")
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
