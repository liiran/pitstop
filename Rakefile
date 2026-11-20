require "rake/testtask"

Rake::TestTask.new("test") do |t|
  t.libs << "lib" << "test"
  t.test_files = FileList["test/unit/**/*_test.rb"]
  t.warning = false
end

task default: :test
