module Pitstop
  # Sorts a changed file into what it means for test selection:
  #
  #   :ignore  nothing to test (docs, CI config)            "README.md"
  #   :global  could affect any test, so run them all       "Gemfile.lock", "test/test_helper.rb"
  #   :test    a test file, so run that file                "test/models/cart_test.rb"
  #   :ruby    app code the map can follow                  "app/models/cart.rb"
  #   :browser only a browser can see it (CSS, JS, images)   "app/assets/stylesheets/cards.css"
  #   :other   a file the map can't follow yet (run all)    "app/views/carts/show.html.erb"
  class Rules
    Verdict = Struct.new(:kind, :reason)

    DEFAULTS = {
      "ignore" => %w[
        .pitstop/** **/*.md **/*.markdown **/*.txt **/*.rdoc LICENSE* CHANGELOG* CHANGES* NEWS* AUTHORS*
        docs/** doc/** changelog/** relnotes/** .github/** .gitlab/** .circleci/** .buildkite/**
        .gitignore .gitattributes .editorconfig .rubocop*.yml .yardopts .dockerignore .devcontainer/**
        **/.keep **/.gitkeep
        Dockerfile* **/Dockerfile* .kamal/** **/.kamal/** config/deploy*.yml **/config/deploy*.yml Procfile* bin/** script/** **/bin/setup **/bin/dev
      ],
      "global" => %w[
        Gemfile Gemfile.* gems.rb gems.locked *.gemspec .ruby-version .tool-versions .mise.toml
        Rakefile config.ru .rspec .pitstop.yml exe/**
        config/** db/schema.rb db/*schema*.rb db/structure.sql db/*structure*.sql db/migrate/**
        test/test_helper.rb spec/spec_helper.rb spec/rails_helper.rb
      ],
      "browser" => %w[
        app/assets/** app/javascript/** **/app/assets/** **/app/javascript/** public/**
        **/*.css **/*.scss **/*.sass **/*.js **/*.mjs **/*.ts **/*.svg **/*.png **/*.jpg **/*.jpeg **/*.gif
        **/*.webp **/*.ico **/*.woff **/*.woff2
      ],
      "tests" => %w[test/**/*_test.rb spec/**/*_spec.rb],
      "test_support" => %w[test/**/*.rb spec/**/*.rb],
      "ruby" => %w[**/*.rb **/*.rake]
    }.freeze

    FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH

    def initialize(overrides = {})
      @lists = DEFAULTS.to_h do |key, list|
        # "docs/**" should mean everything under docs/, at any depth.
        [key, (list + Array(overrides[key])).map { _1.sub(%r{/\*\*\z}, "/**/*") }]
      end
    end

    def classify(path)
      # Before anything else: these settings decide what's ignored, so no `ignore` pattern (not
      # even "**/*") can hide a change to them.
      return Verdict.new(:global, "Pitstop's settings") if path == ".pitstop.yml"
      return Verdict.new(:ignore, "docs or project metadata") if match?("ignore", path)
      return Verdict.new(:global, "app-wide file") if match?("global", path)
      return Verdict.new(:test, "test file") if match?("tests", path)
      return Verdict.new(:global, "test support code") if match?("test_support", path)
      return Verdict.new(:ruby, "Ruby code") if match?("ruby", path)
      return Verdict.new(:browser, "browser-only file") if match?("browser", path)

      Verdict.new(:other, "#{other_kind(path)} (not followed yet)")
    end

    # A short name for a non-Ruby file, so reports can say what blocks selection most often.
    def other_kind(path)
      case path
      when %r{\A(test|spec)/fixtures/} then "test fixture"
      when %r{\A(test|spec)/} then "test data"
      when %r{(\A|/)views/}, /\.(erb|haml|slim|jbuilder|builder)\z/ then "template"
      when /\.ya?ml\z/ then "YAML file"
      else
        ext = File.extname(path)
        ext.empty? ? "file without extension" : "#{ext} file"
      end
    end

    private

    def match?(list, path)
      @lists.fetch(list).any? { |pattern| File.fnmatch?(pattern, path, FLAGS) }
    end
  end
end
