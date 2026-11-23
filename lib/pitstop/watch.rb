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
      test_class = nil
      TracePoint.new(:class) do |tp|
        # Module#name itself: some classes redefine `name` (or `self.name`) as a DSL.
        case MODULE_NAME.bind_call(tp.self)
        when "Minitest::Test"
          test_class = tp.self
          minitest&.call
        when "RSpec::Core::Runner" then rspec&.call(tp.self)
        when "SimpleCov" then simplecov&.call(tp.self)
        else
          (OPENED[tp.self] ||= []) << tp.path if test_class && tp.self.is_a?(Class) && tp.self < test_class
        end
      end.tap(&:enable)
    end

    # The files that open each Minitest test class, in the order they loaded. Nearly always one
    # file; when two test files open the same class, each test belongs to the file it's written in.
    OPENED = {}.compare_by_identity

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

    # The file a Minitest test belongs to: the file to hand the test command so the test runs, and
    # the file whose change runs it. That's the file that defines its class (so tests mixed in
    # from a module, or made by a helper, still belong to the test file that runs them), or else
    # the file the test method is written in.
    def self.minitest_file(klass, method_name)
      method = begin
        klass.instance_method(method_name)
      rescue NameError
        nil
      end
      written_in = method&.source_location&.first
      name = MODULE_NAME.bind_call(klass)
      class_file = begin
        Object.const_source_location(name)&.first if name&.match?(/\A[A-Z]\w*(::[A-Z]\w*)*\z/)
      rescue NameError
        nil
      end
      return written_in if class_file.nil? || class_file.empty?
      # A second test file that opens the same class: the tests written there are that file's.
      return written_in if written_in && written_in != class_file && method.owner == klass && OPENED[klass]&.include?(written_in)

      class_file
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
