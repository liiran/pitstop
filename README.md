# Pitstop

Runs only the tests your change can affect, for Ruby and Rails. Work in progress.

Your suite has 2,000 tests and you changed one method. Pitstop knows which tests ran that method
the last time the whole suite ran, so it runs those 37 and skips the rest:

```
$ pitstop run
Pitstop: map from a1b2c3d, 2184 tests
  app/models/cart.rb        Cart#total changed               → 37 tests
  test/models/cart_test.rb  test file changed (whole file)   → 12 tests
Running 41 of 2184 tests (1.9%), plus 1 whole test file: test/models/cart_test.rb
...
Pitstop: ran 41 of 41 selected tests, plus 12 from whole test files
```

It works with Minitest (5 and 6, including Rails' parallel workers) and RSpec, and needs Ruby 3.2+.

## How to use it

```sh
pitstop record          # run every test once, noting which code each test runs (the "map")
pitstop list --explain  # which tests your changes since then can affect, and why
pitstop run             # run only those
```

Record on your main branch (in CI, or once in a while locally), then `pitstop run` as you work.
Changes are compared with the commit the map was recorded at, so committed and uncommitted
changes count the same.

The test command is `bin/rails test`, `bundle exec rspec` (a project with `spec/` and no `test/`) or
`bundle exec rake test`. Pick another with `pitstop record -- <command>`, or in `.pitstop.yml`.

## What it picks

| You changed | Pitstop runs |
|---|---|
| A method or block (`def total`, `scope :recent, -> {…}`) | the tests that ran its old lines |
| A method that runs while the app boots | everything (said why) |
| Code outside methods (`MAX = 3`, `validates`, `include`), or added a method | every test that ran the file |
| A template Ruby's coverage saw (ERB) | every test that rendered it |
| A deleted or renamed file | every test that ran the old file |
| A test file (changed or new) | that whole file |
| `Gemfile.lock`, `config/**`, `db/schema.rb`, migrations, test helpers and support files | everything (said why) |
| Any other file no recorded test read (JSON, YAML…) | everything (said why) |
| Docs, CI settings, CSS, JavaScript, images | nothing |
| Only comments or blank lines | nothing |

Tests that failed or were skipped when the map was made always run: their lines weren't all
recorded. If the map's commit isn't in your repo, everything runs.

## Checks it makes

`pitstop record` warns when the map would miss tests: when the framework ran more tests than
Pitstop recorded, or when project files loaded before coverage started (something else loaded
them first, such as another `RUBYOPT -r` or a preloader). It refuses to record tests running on
several threads at once, because their lines can't be told apart. A Ruby process a test starts
(a CLI test, say) is recorded as part of that test.

`pitstop run` checks that every selected test actually ran. A run that quietly ran fewer tests
than it selected would look like a perfect pass, so it fails instead (exit status 3), naming the
tests that didn't run.

## .pitstop.yml

Extra patterns for each list, added to the defaults, and the test command:

```yaml
command: bin/rails test
ignore: ["Gemfile.saas*"]      # changes here never need tests
global: ["app/lib/money.rb"]   # changes here run everything
```

The lists are `ignore`, `global`, `browser`, `tests`, `test_support` and `ruby`.

## Developing

```sh
ruby -Ilib -Itest -e 'Dir["test/unit/*_test.rb"].each { require "./#{_1}" }'
```

The tests build small throwaway projects in real git repos and run the real `pitstop` on them.
For the framework matrix, install the extra gems outside your system gems:

```sh
gem install --install-dir tmp/gems minitest:6.1.0 minitest:5.27.0 rspec activesupport
```

Anything that forks (Rails' parallel workers, a test that forks) is tested on Linux; on Windows
those tests skip. `compose.yaml` has a Linux environment.
