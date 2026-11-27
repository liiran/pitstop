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

## How much faster

It depends on what you change. Measured on [Fizzy](https://github.com/basecamp/fizzy), a Rails
app with 2,708 tests whose whole suite took 25 seconds on the day of this table:

| You changed | Tests run | Whole suite | `pitstop run` |
|---|---|---|---|
| The inside of one controller action | 9 | 24.7 s | 3.1 s |
| One template | 14 | 24.7 s | 4.0 s |
| A stylesheet | 18 | 24.7 s | 3.8 s |
| The inside of one model method | 142 | 24.7 s | 8.6 s |
| The inside of a method nearly every request runs | 1,031 | 24.7 s | 18.7 s |
| A constant, or a settings file | all 2,708 | 24.7 s | 24.7 s |

Real commits are not all changes inside one method, so the saving over a project's history is
much smaller. Replaying Fizzy's last 29 commits one by one, `pitstop run` took 6.6 minutes in
all where the whole suite each time took 10.4 (37% less): 7 commits changed nothing a test can
be affected by, 6 ran between 9 and 132 tests, and 16 ran everything. Ten of those 16 were
library updates, and four changed code that runs when a file loads (see
[below](#code-that-runs-when-a-file-loads)). Over RuboCop's last 8 commits it took 20.1 minutes
where the whole suite took 26.0 (22% less): 5 of the 8 ran everything, for the same reason.

To check that nothing gets missed, 92 small bugs were planted one at a time, 52 inside methods
and 40 outside them. For each one, the whole suite ran and `pitstop run` ran:

| | Bugs |
|---|---|
| Planted | 92 |
| No test notices the bug: the whole suite passes with it too | 22 |
| The whole suite fails | 70 |
| ... and `pitstop run` fails as well | 70 of 70 |

The 22 are gaps in the projects' own tests, and say nothing about Pitstop. For the 40 bugs
outside methods the check went one step further: every test the whole suite failed, 6,761 in
all, had to be among the tests Pitstop picked. Every one was.

Files that tests read were changed the same way, 52 of them one at a time (emptied, deleted or
added). Seven of those changes made tests fail, 35 tests in all, and all 35 were among the ones
Pitstop picked.

What it costs, and where it doesn't help:

- **Recording the map takes 1.3 to 1.8 times a normal run**, and it has to be redone at every
  merge: on Fizzy, a map three commits old ran everything at 25 of 27 commits.
- **A suite whose time goes to a few broad, slow tests gains little.** A small gem whose tests
  start whole Rails apps gained nothing.
- **In CI the recording on the main branch has to be earned back.** On both projects a pull
  request came out ahead from its third test run.

How this was measured, every number, and what the numbers don't show:
[bench/RESULTS.md](bench/RESULTS.md).

## Install

Pitstop isn't published on RubyGems (so `gem install pitstop` would not get you this
project). Install it from a clone:

```sh
git clone https://github.com/liiran/pitstop
cd pitstop
gem build pitstop.gemspec
gem install ./pitstop-*.gem
```

That gives you the `pitstop` command. It needs Ruby 3.2 or newer and git. Its one dependency,
Prism, is installed with it. Pitstop doesn't go in your project's `Gemfile`: it starts your
test command from outside, and what it loads into the test process uses nothing but Ruby's
own libraries.

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

### In CI

- **On your main branch:** run `pitstop record` instead of the plain test command. It runs every
  test (so main is always fully tested) and leaves `.pitstop/map.json.gz`. Keep that file for
  other jobs, as a cache or an artifact.
- **On a pull request:** fetch main's map into `.pitstop/`, then `pitstop run`. With no map there,
  run your normal test command instead.

The pull request's checkout needs the commit the map was made at (a full clone, not a shallow
one). If that commit is missing, Pitstop runs everything and says why.

| Exit status | Meaning |
|---|---|
| 0 | the selected tests passed (or nothing needed running) |
| 1 | tests failed, or the map couldn't be used |
| 3 | some selected tests didn't run, so the change isn't covered |
| 64 | wrong usage: no map yet, an unknown option, a bad `.pitstop.yml` |

## What it picks

| You changed | Pitstop runs |
|---|---|
| The inside of a method or block (`def total … end`, a `scope` or callback block) | the tests that ran its old lines |
| A method that runs while the app boots | everything (said why) |
| Code that runs when a file loads (see below) | everything (said why) |
| A template Ruby's coverage saw (ERB) | every test that rendered it |
| A new template | everything (said why) |
| A test file (changed or new) | that whole file, if the test command runs it (see below) |
| `Gemfile.lock`, `config/**`, `db/schema.rb`, migrations, test helpers and support files | everything (said why) |
| Any other file (JSON, YAML, fixtures…) | everything (said why), also when a test was seen reading it |
| Docs, CI settings, CSS, JavaScript, images | nothing, unless a recorded test read the file or looked for it |
| A doc, script or browser file that a test read, or whose folder a test listed (see below) | the tests that read it or listed it |
| Only comments or blank lines | nothing |

Tests that failed or were skipped when the map was made always run: their lines weren't all
recorded. If the map's commit isn't in your repo, everything runs.

### Code that runs when a file loads

A method's lines run when a test calls it, so the map knows which tests those are. Other code
runs once, when its file loads, which is before the first test. No test is linked to it, and a
test can still depend on it:

```ruby
# lib/limits.rb                      # lib/cart.rb
module Limits                        def full?
  MAX = 3                              @items.size >= Limits::MAX
end                                  end
```

A test of `Cart#full?` never runs a line of `lib/limits.rb`, and breaks when `MAX` changes.
So these changes run everything:

- **anything outside a method:** a constant, `validates`, `has_many`, `include`, `private`
- **a method added under a name that was already a method somewhere** (`def to_s`,
  `def initialize`, `def to_param` in a model): it may be replacing the one tests relied on
- **a method that is one line or empty** (`def max = 3`, a Rails action that only renders): its
  line runs on loading, and a call to it leaves nothing the map could tell apart
- **a Ruby file added, deleted or renamed**

Two exceptions, where Pitstop can be sure:

- **A file nothing loaded while the map was recorded** can't be changing what those tests do.
  It picks nothing.
- **A method added under a name nothing used before**, which is what most added methods are: a
  helper written for the change at hand. The recording keeps the name of every method any class
  had (the project's, its gems', Ruby's). When the new name is not among them, appears nowhere
  in the project's files, and belongs to a class whose methods no code lists, nothing could have
  been calling it. Pitstop picks the tests that ran the file, and the changed code that calls
  the new method is picked for its own change. The one thing this takes on trust: no code was
  already reaching for that name by building it (`public_send("on_#{kind}")`).

### Files a test reads

A test can also depend on a file without running a line of it, by reading it:

```ruby
# spec/changelog_spec.rb
Dir["changelog/*.md"].each do |path|                 # one example per changelog entry
  it "#{path} starts with a star" do
    expect(File.read(path)).to start_with("* ")
  end
end
```

"Docs run nothing" would skip this spec when an entry is edited, and when one is added. So
while it records, Pitstop also notes which of the project's files Ruby code opens, which
folders it lists (and with what pattern), and which files it checks for:

| What happened | Pitstop runs |
|---|---|
| A file that a test read was changed | the tests that read it |
| A file was added, deleted or renamed, and a test had listed its folder (`Dir["changelog/*.md"]`) or checked for it (`File.exist?`) | the tests that did |
| The reading or listing was done by a test file's own code as it loaded (the `Dir[...]` above) | that whole test file, so an example gets made for the new entry |
| It was done while the app was starting | everything (said why) |

- **A spec that reads your source files as text** runs when one of them changes, even if only
  a comment did.
- **This only ever adds tests.** A file no test read is treated as the table at the top says.
- **Other data files still run everything.** A JSON or YAML file that isn't docs runs everything
  when it changes, whether or not a test was seen reading it: such a file may be used in ways
  no read shows.
- **Your own `ignore` line wins.** If `.pitstop.yml` ignores a file that tests read, they are
  left out, and the output says so.

**What this leaves out, and the setting for it.** A test can use what an earlier test read,
without opening the file itself:

```ruby
def notes = $notes ||= File.read("docs/notes.md")   # read once, then kept in memory

def test_b = assert_includes(notes, "Setup")        # opens the file: linked to it
def test_c = assert_includes(notes, "Usage")        # gets the kept text: not linked
```

Change `docs/notes.md` and Pitstop picks `test_b`. It doesn't pick `test_c`, which nothing in
the recording ties to the file, though the change can break it. That failure shows up the next
time everything runs (recording the map is such a run), so it is found late, not never.

`tests_after_readers: true` in `.pitstop.yml` closes this. Then every test that ran after a
reader in the same process runs too, since any of them may be using what it read:

| | `docs/notes.md` changes | The price |
|---|---|---|
| Default | runs `test_b` | `test_c` is left out |
| `tests_after_readers: true` | runs `test_b`, `test_c` and every other test that ran after `test_b` | most of those tests have nothing to do with the file; for a file read early in a run, it is most of the suite |

Measured: every RuboCop commit adds a changelog entry, which one of its specs reads. Over its
last 8 commits `pitstop run` saved 22% of the test time by default and 9% with the setting,
which ran about 24,000 of its 36,500 tests at two commits where the default ran about 1,300. When
files that tests read were changed on purpose in RuboCop and Fizzy (52 changes, 35 failing
tests), the default left none of the failing tests out. No test like `test_c` turned up in
either project, which says the case is uncommon there, not that it can't happen
([the numbers](bench/RESULTS.md#files-that-tests-read)).

The setting never applies to a file whose lines the map follows (Ruby, templates): what stays
in memory from such a file is code, and a test that runs that code is linked to it anyway.

What Pitstop can't see with either setting, and you list under `global` in `.pitstop.yml`:

- **A file opened by a program that isn't Ruby,** such as a test that runs `git ls-files` or
  `cat`, or by a gem's own C code. A Ruby program that a test starts is followed.
- **A file read by a process that never runs a test,** such as the `rake` that starts the tests.
- **A test file that reads something as it loads, for the use of other test files.** That
  reading is taken to matter to the test file that did it.

One more kind of test needs care:

- **Tests that drive a browser** (Rails system tests). They depend on CSS and JavaScript, which
  Pitstop doesn't follow. Run them whole, as their own command. `bin/rails test` leaves
  `test/system` out, and so does Pitstop: a changed file in there is named in the output as left
  out, and not run.

## Checks it makes

`pitstop record` warns when the map would miss tests: when the framework ran more tests than
Pitstop recorded, or when project files loaded before coverage started. A change to one of those
files runs everything. (`bundle exec` loads a gem's gemspec, and the version file it requires,
first; anything more means something else loaded code early, such as another `RUBYOPT -r` or a
preloader.) It refuses to record tests running on several threads at once, because their lines
can't be told apart.

Some tests run other code as part of themselves, and Pitstop counts that code as part of the test:
- a Ruby process the test starts (a CLI test, say)
- a test the test builds and runs inside itself (a test of a test helper)
- a whole test suite the test runs in a subprocess

When recording, their lines belong to the outer test. When running, Pitstop doesn't filter them.

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

The lists are `ignore`, `global`, `browser`, `tests`, `test_support` and `ruby`. A change to
`.pitstop.yml` itself always runs everything, whatever its `ignore` list says.
`tests_after_readers: true` is the one other setting (see
[Files a test reads](#files-a-test-reads)).

Your own patterns are checked before the built-in ones, so they can overrule them either way.
`ignore: ["Gemfile.saas*"]` stops a lockfile your tests never use from running everything.
`global: ["changelog/**"]` makes a change to a docs folder run everything, for a project where
something Pitstop can't see reads it. Where two of your own lists match the same file, `global`
wins.

`command` is a list of words (`bin/rails test` is two), started directly: nothing in it is read
by a shell, so `&&`, `>` and `$VAR` mean nothing there. For those, point it at a script.

## A project inside a bigger repository

Run Pitstop from the project's own folder (the one with its `Gemfile` and tests), say `backend/`
in a repository that also holds `frontend/`. Files elsewhere in the repository show up with `../`:

```
$ cd backend && pitstop list
  ../frontend/src/app.js   browser-only file                                          → 0 tests
  ../common/lib/money.rb   outside this project's folder, where the map can't follow it  → all tests
```

Docs and browser files elsewhere pick nothing. Anything else there runs everything, because the
map only follows files inside the project's folder. If a folder beside yours can't affect your
tests, say so:

```yaml
ignore: ["../mobile/**"]
```

## SimpleCov

Ruby has one coverage counter, and Pitstop and SimpleCov both read it.

- **`pitstop record`** switches SimpleCov off for that run and says so. (SimpleCov would report
  nothing covered, fail a `minimum_coverage` setting and overwrite your last real report.)
- **`pitstop run`** leaves SimpleCov alone, but a run of 40 tests out of 2,000 covers far less
  code than the whole suite. If you enforce a minimum, skip it for partial runs. Pitstop sets
  `PITSTOP` to `record` or `run` in the test process:

```ruby
SimpleCov.start do
  minimum_coverage 90 unless ENV["PITSTOP"] == "run"
end
```

## Safety

What Pitstop does on your machine, so you can decide where to use it:

- **It runs your test command, and nothing else.** No network access, no telemetry, nothing sent
  anywhere.
- **It writes only inside `.pitstop/`** in your project: the map, and working files it removes
  when a run ends. `.pitstop/` keeps itself out of git.
- **The map holds** these, and nothing else:
  - test names, file paths inside the project, line numbers, a commit id and the order the
    tests ran in;
  - the names of project files your tests read or looked for, and the patterns they listed
    folders with. Names only: `.env` can appear in a map if a test read it, what it says
    can't. In a Rails app these include the paths its tests requested, because Rails looks
    for each one under `public/`;
  - the names of methods (your code's, your gems' and Ruby's) and of your project's classes.

  It holds no source code, no file contents, no environment variables and no paths from
  outside the project.
- **The map and `.pitstop.yml` are read as plain data** and checked before use. A map that isn't
  one Pitstop wrote is refused.
- **`pitstop list` runs no project code.** It reads the map and asks git what changed.
- **The map decides which tests get skipped**, so use one made by a build you trust (your main
  branch's CI), not one that arrives with the change being tested.

`pitstop record` and `pitstop run` load a small file into the test process through `RUBYOPT`, and
every Ruby process your tests start inherits it. In a process run by an older Ruby, or by JRuby,
it does nothing.

While recording (not during `pitstop run`), that file also puts small methods of its own in
front of Ruby's file methods (`File.read`, `File.exist?`, `Dir.glob` and the like) and its
method listings (`instance_methods`, `methods`), to note what your tests read. They hand every
call on unchanged and give back what Ruby gives back. What a test could still notice:

- those methods report a different `arity`, and `File`, `IO`, `Dir`, `FileTest`, `Module` and
  `Kernel` (so every object) gain private methods named `__pitstop_…`;
- on Ruby before 3.4, an error raised by one of them (`File.read` of a missing file) has one
  extra line at the top of its trace;
- code that runs in another Ractor works as usual, but what it reads isn't noted.

To report a security problem, see [SECURITY.md](SECURITY.md).

## Developing

```sh
ruby -Ilib -Itest -e 'Dir["test/unit/*_test.rb"].each { require "./#{_1}" }'
```

The tests build small throwaway projects in real git repos and run the real `pitstop` on them.
For the framework matrix, install the extra gems outside your system gems:

```sh
gem install --install-dir tmp/gems minitest:6.1.0 minitest:5.27.0 rspec activesupport simplecov minitest-reporters
```

Anything that forks (Rails' parallel workers, a test that forks) is tested on Linux; on Windows
those tests skip. `compose.yaml` has a Linux environment.

Three environment variables exist for working on Pitstop itself, and none is needed to use it:
`PITSTOP_KEEP_RUNS=1` keeps the working files of a recording in `.pitstop/runs/`,
`PITSTOP_GRANULARITY=test` or `file` fixes how often coverage is read while recording, and
`PITSTOP_EAGER_LOAD=0` stops a recording from loading a Rails app's code up front.

`bench/` holds the scripts that run Pitstop on real apps (one change at a time, their real
commits replayed, planted bugs), the numbers they produced (`bench/results/`) and the page
written from them, [bench/RESULTS.md](bench/RESULTS.md).
