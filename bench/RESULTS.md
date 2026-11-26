# How much time Pitstop saves, measured

Pitstop was timed on three projects, three ways:

1. **One change at a time.** A fixed list of changes to each project (a docs edit, one method, a
   template, a settings file and so on), each timed next to the whole suite.
2. **Real history.** The projects' own recent commits, replayed one by one.
3. **Planted bugs.** Small bugs put into code the tests run, to check that the tests Pitstop picks
   catch every bug the whole suite catches.

| Project | What it is | Tests | Test command |
|---|---|---|---|
| [Fizzy](https://github.com/basecamp/fizzy) | A Rails 8 app | 2,708 (Minitest, 12 processes at once) | `bin/rails test` |
| [RuboCop](https://github.com/rubocop/rubocop) | A code checker, plain Ruby | 36,505 (RSpec, one process) | `bundle exec rspec` |
| [Dead Heat](https://github.com/liiran/deadheat) | A small gem whose tests start real Rails apps | 95 (Minitest) | `bundle exec rake test:once` |

Measured in November 2026, at commits `67305be` (Fizzy), `a97adf3` (RuboCop) and `c649a88`
(Dead Heat).

## The short version

- **Changing the inside of one method in a Rails app takes a few seconds instead of the whole
  suite's 25.** On Fizzy, a change inside one controller action, template, job or model method
  ran 9 to 205 of the 2,708 tests and took 3 to 9 s.
- **Over real history the saving is much smaller: 37% of the test time on Fizzy, 22% on
  RuboCop.** Replaying Fizzy's last 29 commits one by one, `pitstop run` took 6.6 minutes in all
  where the whole suite each time took 10.4. RuboCop's last 8 commits took 20.1 minutes where
  the whole suite took 26.0.
- **Most real commits run everything, and rightly.** 16 of Fizzy's 29 did: ten library updates,
  two settings files, and four that changed code which runs when a file loads (a file added, a
  line outside any method). 5 of RuboCop's 8 did, for a line outside any method or a method
  added under a name that already existed. A test can depend on such code without running a
  line of it, so Pitstop doesn't narrow it.
- **Some suites gain nothing.** Dead Heat's time goes to a few tests that start whole Rails apps.
  A change to nearly any file runs them, and `pitstop run` was a second slower than the whole
  suite.
- **No planted bug got through.** 92 small bugs were planted, 52 inside methods and 40 outside
  them. The whole suites catch 70 of them, and `pitstop run` failed for every one of those. For
  the 40 outside methods every failing test was checked: 6,761 in all, none left out.
- **A changed file runs the tests that read it.** A spec that checks the changelog runs when an
  entry changes: 35 tests failed when RuboCop's entries were emptied one by one, and all 35
  were picked. A test that only uses what an earlier test read is left out unless
  `tests_after_readers` is on, and with it on RuboCop saves 9% over its history, not 22%
  (see [Files that tests read](#files-that-tests-read)).
- **The map costs something.** Recording takes 1.3 to 1.8 times a plain run, and it has to be
  redone at every merge: on Fizzy, a map three commits old ran everything at 25 of 27 commits.
- **In CI the recording has to be earned back.** On both projects it takes a pull request's
  third test run to come out ahead.
- **Measuring this found four bugs in Pitstop**, all fixed. The worst let a failing test be
  skipped (see [Did it miss anything?](#did-it-miss-anything)).

## How it was measured

- **Whole suite** is the project's normal test command, without Pitstop.
- **With Pitstop** is `pitstop run`, the whole command: reading the map, asking git what changed,
  picking the tests, running them, and checking that every picked test ran.
- Both are timed from the moment the command starts to the moment it exits, on the same machine,
  in the same session, taking turns.
- Every command runs with a terminal attached, the way you run it yourself. This matters more than
  it sounds: Fizzy's progress bar makes its whole suite take 54 s when the output goes to a file
  and 20 s in a terminal. Timing to a file would have made Pitstop look more than twice as good
  as it is.
- In the tables of single changes, each time is the middle one of three runs (for RuboCop, the
  mean of two).
  In Fizzy's replay each side counts with the best of two or three timings; in RuboCop's, each
  commit was timed once (the reasons are there). A commit where Pitstop runs everything isn't
  timed twice: `pitstop run` is then the whole suite plus the picking, and that is what's counted.
- The single changes were timed on 26 November, the replays over the days before. The machine
  was slower that day (Fizzy's whole suite took 25 s where it had taken 20, RuboCop's 219 s
  where it had taken 196). Both sides of every row were timed in the same session, so the
  differences hold; the seconds of one table shouldn't be set against another's.
- The map is recorded before the timing starts. What recording costs is its own section.
- The machine is a desktop in everyday use (AMD Ryzen 5 9600X, 6 cores and 12 threads), running
  the projects in Linux containers with an 8 GB memory limit, on Ruby 4.0 (Dead Heat on 3.4).
  It is not a quiet lab machine: a browser and other programs were open.

These are the numbers research on test selection reports: the share of tests picked, the time
from start to finish next to running everything, and the cost of collecting the map
(see [What other tools publish](#what-other-tools-publish)).

## One change at a time

Each row is one change made by hand, then undone. The list is in `bench/e2e/<project>.txt`.

### Fizzy

<!-- changes:fizzy -->
| What changed | Tests run | Whole suite | With Pitstop | Difference |
|---|---|---|---|---|
| Comment only (the same always-run tests) | 6 of 2,708 (0.2%) | 24.7 s | 2.7 s | 9.3× faster |
| Docs only (only the always-run skipped tests) | 6 of 2,708 (0.2%) | 24.7 s | 2.7 s | 9.3× faster |
| Controller action | 9 of 2,708 (0.3%) | 24.7 s | 3.1 s | 7.9× faster |
| Test file | 12 of 2,708 (0.4%) | 24.7 s | 2.8 s | 8.8× faster |
| Template | 14 of 2,708 (0.5%) | 24.7 s | 4.0 s | 6.2× faster |
| Stylesheet (the tests that read it) | 18 of 2,708 (0.7%) | 24.7 s | 3.8 s | 6.5× faster |
| Job | 20 of 2,708 (0.7%) | 24.7 s | 4.7 s | 5.2× faster |
| View helper | 120 of 2,708 (4.4%) | 24.7 s | 8.9 s | 2.8× faster |
| Method, same behaviour | 142 of 2,708 (5.2%) | 24.7 s | 8.6 s | 2.9× faster |
| Planted bug in a method | 205 of 2,708 (7.6%) | 24.7 s | 8.4 s | 3.0× faster |
| Method nearly every request runs | 1,031 of 2,708 (38%) | 24.7 s | 18.7 s | 1.3× faster |
| Constant in the main model | 2,708 of 2,708 (100%) | 24.7 s | 24.7 s | the same |
| Test settings (runs everything) | 2,708 of 2,708 (100%) | 24.7 s | 24.8 s | the same |
| Planted bug in a lambda scope | 2,708 of 2,708 (100%) | 24.7 s | 25.1 s | the same |
<!-- /changes:fizzy -->

How to read it:

- **The floor is about 2.7 s.** That is Rails starting, plus the six tests Fizzy skips, which
  always run. No selection can go below it.
- **Most changes inside one method of a model, controller or job, or to a template, run a few
  dozen tests** and finish in 3 to 9 s.
- **A stylesheet runs the 12 tests that read it** (and the six that always run): the first test
  to render a page in each of the twelve test processes. Before Pitstop noted which files tests
  read, it ran nothing for a stylesheet.
- **The more of the app a method is part of, the less there is to skip.** One that runs on nearly
  every request runs over a thousand tests.
- **Code that runs when a file loads runs everything.** The constant in the `Card` model and the
  one-line scope are examples: no test is linked to such code, and any test may depend on it
  (see [the README](../README.md#code-that-runs-when-a-file-loads)).
- **A settings file runs everything**, and takes as long as the whole suite, because Pitstop
  can't tell what a setting affects.

### RuboCop

<!-- changes:rubocop -->
| What changed | Tests run | Whole suite | With Pitstop | Difference |
|---|---|---|---|---|
| Comment only (the specs that read the file as text) | 53 of 36,505 (0.1%) | 219 s | 41.1 s | 5.3× faster |
| Spec file | 713 of 36,505 (2.0%) | 219 s | 12.7 s | 17× faster |
| Badly formed changelog entry (the changelog's specs catch it) | 717 of 36,505 (2.0%) | 219 s | 12.9 s | 17× faster |
| Planted bug in a cop | 854 of 36,505 (2.3%) | 219 s | 98.9 s | 2.2× faster |
| Method, same behaviour | 854 of 36,505 (2.3%) | 219 s | 99.5 s | 2.2× faster |
| Output formatter | 891 of 36,505 (2.4%) | 219 s | 104 s | 2.1× faster |
| Command line | 942 of 36,505 (2.6%) | 219 s | 112 s | 2.0× faster |
| Planted bug in a shared mixin | 2,148 of 36,505 (5.9%) | 219 s | 114 s | 1.9× faster |
| Method every cop run goes through | 33,661 of 36,505 (92%) | 219 s | 204 s | 1.1× faster |
| Default settings (runs everything) | 36,505 of 36,505 (100%) | 219 s | 217 s | the same |
<!-- /changes:rubocop -->

How to read it:

- **Every run here includes eight tests it shouldn't need, and they take about 10 s.** Five of
  RuboCop's tests fail in this container whatever runs them: it has no `ps` command, it runs
  as root, and its Bundler prints a warning those tests don't expect. Pitstop always runs the
  tests that were failing or pending when the map was made, so every run includes those five
  and three pending ones, and they are slow.
- **A comment in a cop runs 53 tests and takes 41 s.** No code changed, but 45 specs read
  RuboCop's own source files as files: its result cache makes a checksum of them, and the
  specs that run RuboCop as a program or start its server go through that. They are slow
  tests. Before Pitstop
  noted which files tests read, this row ran only the eight above.
- **A spec file, or a changelog entry, runs about 700 tests in 13 s.** RuboCop has one spec file
  whose tests read every other spec file and every changelog entry. The changelog entry in
  this list is badly formed, and that spec fails on it (see
  [Files that tests read](#files-that-tests-read)).
- **A change to one cop runs 2% of the tests and takes almost half the time.** The cop's own specs
  take a second. The rest is RuboCop's command-line specs: each one runs every cop over some
  code, so each one ran the changed cop, and they are the slow tests.
- **A method every cop run goes through runs 92% of the tests**, and saves almost nothing.

### Dead Heat

<!-- changes:deadheat -->
| What changed | Tests run | Whole suite | With Pitstop | Difference |
|---|---|---|---|---|
| Comment only | none | 12.2 s | 0.2 s | 61× faster |
| Docs only | none | 12.2 s | 0.2 s | 61× faster |
| Planted bug in the verdict | 22 of 95 (23%) | 12.2 s | 13.8 s | 13% slower |
| Planted bug in a method | 24 of 95 (25%) | 12.2 s | 13.7 s | 13% slower |
| Method, same behaviour | 37 of 95 (39%) | 12.2 s | 13.6 s | 12% slower |
<!-- /changes:deadheat -->

Dead Heat is here because it gains nothing, and it's worth seeing why. Its suite is short, and
almost all of its time goes to a few tests that start whole Rails apps. A change to nearly any
file runs those tests, so the selection has a quarter to two fifths of the tests and over nine
tenths of the time, and Pitstop's own second of overhead makes the run slightly slower than the
whole suite.
A docs or comment change still finishes in a fifth of a second.

## Real commits

One change at a time shows what is possible. Real commits show what you get, because many real
commits are not small changes to one method: they update a library, edit a settings file or touch
only docs.

For each commit, oldest first:

1. The map is the one recorded at the commit before it, as a CI job on the main branch would
   leave it.
2. At the commit, `pitstop run` and the whole suite are both timed (taking turns at going first).
3. The commit is recorded in turn. That recording also says which tests fail at the commit, so a
   test that started failing there and that Pitstop didn't pick would show up as a miss.

No settings file was written for either project: this is Pitstop as installed.

### Fizzy

<!-- replay:fizzy -->
|  | Fizzy |
|---|---|
| Commits replayed | 29 (2026-11-09 to 2026-11-20) |
| Changed nothing a test can be affected by: ran no tests, or only the few that always run | 7 of 29 |
| Ran some of the tests | 6 of 29, half of them under 1.1% of the tests |
| Ran everything (a library update, a settings file, a file the map can't follow) | 16 of 29 |
| Whole suite, every commit | 10.4 min |
| `pitstop run`, every commit | 6.6 min (37% less) |
| Average of each commit's time, as a share of the whole suite | 63% |
| Recording, next to a plain run | 1.83× |
| Tests that started failing at a commit | 0 |
| ... of those, not picked | 0 |
<!-- /replay:fizzy -->

What the 29 commits were:

- **7 changed nothing a test can be affected by** (CI and deploy settings, a pinned tool
  version). Pitstop ran Fizzy's six always-run tests, in 2.5 s.
- **6 changed the inside of methods, templates or tests**, one of them also adding a method
  under a name nothing used before. Pitstop ran between 9 and 132 tests, in 3 to 8 s.
- **16 ran everything:**
  - Ten were library updates (`Gemfile.lock`, `Gemfile`).
  - Two edited settings files. For `config/puma.rb` that was the right call: Fizzy has a test
    that loads it. Tests never load the other, `config/environments/development.rb`, and an
    `ignore` line in `.pitstop.yml` would let Pitstop skip it, but none was written here.
  - Four changed code that runs when a file loads: three added a Ruby file, one changed a line
    outside any method. Two of the three new files sit in a part of the app
    this build never loads, which Pitstop can't know about a file that didn't exist when the map
    was made.

A thirtieth commit, Fizzy's move to Ruby 4.0.10, couldn't be replayed, because one container has
one Ruby. Pitstop runs everything for it (`.ruby-version` changed).

On the timing: this suite keeps all twelve processor threads busy, and on a desktop in use it took
anywhere from 20 to 31 s depending on what else was running, while short runs stayed steady. A
busy stretch therefore flatters Pitstop. So each commit was timed two or three times, and each
side counts with its best time.

<details>
<summary>Every commit</summary>

<!-- commits:fizzy -->
| Commit | What it was | Pitstop picked | Whole suite | With Pitstop |
|---|---|---|---|---|
| `67305be` | Allow full-mark GC during request handling (#3327) | everything: config/puma.rb: app-wide file | 21.8 s | 21.0 s |
| `da4fb42` | Bump aws-sdk-s3 from 1.233.2 to 1.242.0 (#3325) | everything: Gemfile.lock: app-wide file | 22.3 s | 21.7 s |
| `f35c972` | Load the OAuth consent screen in full so Authorize can redire... | 39 of 2,708 tests | 22.1 s | 4.0 s |
| `9060119` | Log Cloudflare's visitor location as client.geo (#3324) | everything: saas/lib/fizzy/saas/client_geo_logging.rb: new Ruby file: it may be loaded by its name or its folder | 21.7 s | 21.9 s* |
| `4da897b` | Pin fizzy-mcp-server v0.2.7 (#3322) | only the 6 tests that always run | 23.3 s | 2.5 s |
| `be11c24` | Register read and write for a dynamic registration that names... | 132 of 2,708 tests | 21.9 s | 4.0 s |
| `09c479e` | Bump solid_queue from 1.7.0 to 1.7.2 (#3310) | everything: Gemfile.lock: app-wide file | 20.8 s | 22.1 s |
| `31a204d` | Bump tzinfo-data from 1.2026.5 to 1.2026.6 (#3277) | everything: Gemfile.lock: app-wide file | 20.2 s | 21.5 s |
| `8c97bf3` | Bump bootsnap from 1.26.0 to 1.26.1 (#3280) | everything: Gemfile.lock: app-wide file | 21.2 s | 21.2 s |
| `255e6db` | Bump mittens from 0.3.4 to 0.3.5 (#3278) | everything: Gemfile.lock: app-wide file | 21.3 s | 21.1 s |
| `fd2694c` | Bump the github-actions group across 1 directory with 4 updat... | only the 6 tests that always run | 21.7 s | 2.4 s |
| `4a3cd2f` | Bump surfguard from `71cac69` to `bcce49e` (#3309) | everything: Gemfile.lock: app-wide file | 20.8 s | 21.6 s |
| `0d47d00` | Bump aws-sdk-s3 from 1.232.1 to 1.233.2 (#3198) | everything: Gemfile.lock: app-wide file | 20.8 s | 21.7 s |
| `5ad7335` | End the connected apps preview in production (#3296) | only the 6 tests that always run | 22.9 s | 2.6 s |
| `0256005` | Pin fizzy-mcp-server v0.2.6 (#3316) | only the 6 tests that always run | 22.6 s | 2.4 s |
| `444464a` | Pin fizzy-mcp-server v0.2.5 (#3313) | only the 6 tests that always run | 22.5 s | 2.4 s |
| `caf08dd` | Drop the runner's MySQL server before installing system packa... | only the 6 tests that always run | 21.5 s | 2.5 s |
| `8e3c3d1` | Upgrade puma to 8.0.3 (#3311) | everything: Gemfile.lock: app-wide file | 20.3 s | 21.4 s |
| `44d60c1` | Bump msgpack from 1.8.5 to 1.8.7 (#3307) | everything: Gemfile.lock: app-wide file | 25.1 s | 24.0 s |
| `b08e794` | Merge pull request #3306 from basecamp/harden-webhook-delivery | everything: app/models/webhook.rb: code outside methods changed: it runs when the file loads | 21.2 s | 21.6 s* |
| `65d432e` | Merge pull request #3302 from basecamp/fix-board-involvement-... | 9 of 2,699 tests | 21.0 s | 3.0 s |
| `abfc4b4` | Merge pull request #3305 from basecamp/activities-deferred-join | 31 of 2,698 tests | 21.2 s | 4.9 s |
| `957830c` | Merge pull request #3286 from basecamp/bump-lexxy-1.0.4 | everything: Gemfile: app-wide file | 22.0 s | 22.1 s |
| `259c624` | Deliver FIZZY_REVIEWER_SIGN_IN_CODES to production (#3282) | everything: saas/test/lib/production_secrets_test.rb: new Ruby file: it may be loaded by its name or its folder | 21.8 s | 22.0 s* |
| `381a1d3` | Merge pull request #3299 from basecamp/fix/public-cache-signe... | 25 of 2,696 tests | 21.4 s | 6.0 s |
| `2de1de3` | Create missing webhook trackers on import (#3294) | 30 of 2,694 tests | 20.2 s | 7.5 s |
| `3cc736b` | Keep rich text attachments Action Text can't read (#3298) | everything: lib/rails_ext/action_text_content_unrecognized_attachments.rb: new Ruby file: it may be loaded by its name or its folder | 20.7 s | 20.8 s* |
| `be713c2` | Pin fizzy-mcp-server v0.2.4 (#3297) | only the 6 tests that always run | 20.1 s | 2.4 s |
| `ad2106e` | Redesign the OAuth consent, Connected apps and error screens ... | everything: config/environments/development.rb: app-wide file | 20.7 s | 21.2 s |

\* Not timed: when Pitstop runs everything, `pitstop run` is the whole suite plus the picking, so that is the time counted (the whole suite's time at that commit, plus the 0.2 s the picking took).
<!-- /commits:fizzy -->

</details>

### RuboCop

<!-- replay:rubocop -->
|  | RuboCop |
|---|---|
| Commits replayed | 8 (2026-11-20 to 2026-11-21) |
| Changed nothing a test can be affected by: ran no tests, or only the few that always run | 0 of 8 |
| Ran some of the tests | 3 of 8, half of them under 3.4% of the tests |
| Ran everything (a library update, a settings file, a file the map can't follow) | 5 of 8 |
| Whole suite, every commit | 26.0 min |
| `pitstop run`, every commit | 20.1 min (22% less) |
| Average of each commit's time, as a share of the whole suite | 76% |
| Recording, next to a plain run | 1.51× |
| Tests that started failing at a commit | 0 |
| ... of those, not picked | 0 |
<!-- /replay:rubocop -->

All eight commits were small fixes to one or two cops: the cop, its spec, sometimes the
command-line autocorrect spec, and a changelog entry. Seven of them added a method, usually a
small helper for the fix.

- **Three ran some of the tests:** 1,096, 1,228 and 1,398 of about 36,400, in 54 to 88 s. Two
  of the three added helpers under names nothing used before.
- **Five ran everything.** Three changed a line outside any method. All five added a method
  under a name that was already a method somewhere:
  - For two it is `autocorrect_incompatible_with`, which every cop inherits. The new one really
    does replace the inherited one, for any test that runs that cop.
  - For the others it is a helper name that other cops also use (`removal_range`,
    `condition_range`). Pitstop knows that some class had a method of that name, not whether
    this class did, so it can't rule out a replacement.

Three things to keep in mind:

- **This is what a cautious rule costs on a project of small fixes.** Knowing which class had
  which methods, not only which names existed, would tell a helper from a replacement in the
  last group.
- **Each of the three commits carries about 700 tests it wouldn't otherwise.** Every commit
  here adds a changelog entry and changes a spec file, and RuboCop has a spec that reads both
  (see [Files that tests read](#files-that-tests-read)). Without them the three would have
  run 397 to 840 tests, and the saving over the eight commits would be 27%, not 22%.
- **Each commit was timed once**, and the five that ran everything weren't timed again: their
  time is the whole suite's.

<details>
<summary>Every commit</summary>

<!-- commits:rubocop -->
| Commit | What it was | Pitstop picked | Whole suite | With Pitstop |
|---|---|---|---|---|
| `a97adf3` | Merge pull request #16403 from Starlexxx/fix_style_for_with_a... | 1,228 of 36,505 tests | 187 s | 59.1 s |
| `a8a8762` | Merge pull request #16471 from koic/fix_an_incorrect_autocorr... | 1,096 of 36,481 tests | 184 s | 54.3 s |
| `628648d` | Merge pull request #16470 from koic/fix_an_incorrect_autocorr... | everything: lib/rubocop/cop/style/raise_args.rb: RuboCop::Cop::Style::RaiseArgs.autocorrect_incompatible_with added: it may replace a method t | 201 s | 202 s* |
| `6effb6f` | Merge pull request #16469 from koic/fix_an_incorrect_autocorr... | everything: lib/rubocop/cop/style/redundant_initialize.rb: RuboCop::Cop::Style::RedundantInitialize#removal_range added: it may replace a meth | 196 s | 196 s* |
| `104e347` | Merge pull request #16468 from koic/fix_an_incorrect_autocorr... | everything: lib/rubocop/cop/style/data_inheritance.rb: RuboCop::Cop::Style::DataInheritance#end_line_kept? added: it may replace a method the  | 200 s | 200 s* |
| `5c1bba5` | Merge pull request #16425 from koic/fix_an_incorrect_autocorr... | everything: lib/rubocop/cop/lint/non_atomic_file_operation.rb: RuboCop::Cop::Lint::NonAtomicFileOperation#condition_range added: it may replac | 192 s | 193 s* |
| `8e01ebf` | Merge pull request #16416 from koic/fix_an_incorrect_autocorr... | everything: lib/rubocop/cop/lint/useless_assignment.rb: RuboCop::Cop::Lint::UselessAssignment.autocorrect_incompatible_with added: it may repl | 215 s | 215 s* |
| `bfac040` | Merge pull request #16415 from koic/fix_an_incorrect_autocorr... | 1,398 of 36,284 tests | 184 s | 87.9 s |

\* Not timed: when Pitstop runs everything, `pitstop run` is the whole suite plus the picking, so that is the time counted (the whole suite's time at that commit, plus the 0.4 s the picking took).
<!-- /commits:rubocop -->

</details>

## Files that tests read

A test can depend on a file without running a line of it. RuboCop has a spec that checks every
entry in `changelog/`. Rails reads each stylesheet the first time a page is rendered. While it
records, Pitstop notes which files each test opens, which folders it lists and which files it
checks for, and a change to such a file runs the tests that did
(see [the README](../README.md#files-a-test-reads)).

**What it costs.** It shows in RuboCop's history, as said above: about 700 more tests on each
commit that picks some of the tests, and 22% saved over the eight commits where it would be
27%. On Fizzy no replayed commit picks differently.

**The stricter setting.** By default only the tests that opened the file run. A test that uses
what an earlier test read and kept in memory isn't linked to the file, and is left out.
`tests_after_readers: true` in `.pitstop.yml` also runs every test that ran after a reader in
the same process. The replayed commits, asked and timed again with it:

<!-- after-readers -->
|  | Commits that pick differently | `pitstop run`, every commit, by default | ... with `tests_after_readers` | Tests run at those commits by default | ... with `tests_after_readers` |
|---|---|---|---|---|---|
| Fizzy, 29 commits | 0 of 29 | 6.6 min (37% less) | 6.6 min (37% less) |  |  |
| RuboCop, 8 commits | 3 of 8 | 20.1 min (22% less) | 23.7 min (9.2% less) | 1,398, 1,096, 1,228 | 24,081, 2,165, 23,549 |
<!-- /after-readers -->

- **RuboCop loses most of its saving: 9% instead of 22%.** Its suite runs in one process, so
  "after the spec that reads the changelog" is whatever happened to run after it when the map
  was recorded: about 24,000 tests at two of the commits, 2,165 at the third.
- **On Fizzy none of the 29 commits changes.** A change to a stylesheet or a script would:
  among the planted changes below, an emptied stylesheet picks 18 tests by default and 2,617 of 2,708 with the
  setting, because the first test to render a page in each of the twelve processes reads them.

**Does the default leave failing tests out?** Files that tests read were changed one at a
time: emptied, deleted, or joined by a new file in a folder that tests had listed. Where
Pitstop ran everything nothing can be left out, so those changes were only counted. For the
rest the whole suite ran, and every test it failed was looked for among the picked ones, under
both settings:

<!-- read-files -->
| Files changed | Ran everything (not checked) | Ran some tests (checked) | ... broke no test | ... broke a test | Tests that failed | ... left out by default | ... left out with `tests_after_readers` | Tests picked by default (median) | ... with `tests_after_readers` (median) |
|---|---|---|---|---|---|---|---|---|---|
| Fizzy | 136 | 40 | 40 | 0 | 0 | 0 of 0 | 0 of 0 | 18 | 2,617 |
| RuboCop | 18 | 12 | 5 | 7 | 35 | 0 of 35 | 0 of 35 | 698 | 25,689 |
<!-- /read-files -->

- **RuboCop:** all twelve were changelog entries. The seven that were emptied each failed five
  checks of the changelog spec, 35 failing tests in all, and the default picked every one. The
  four deleted and the one added broke nothing.
- **Fizzy:** none of the forty broke a test. They were stylesheets, scripts and images (34
  emptied, 6 added), which Fizzy's tests don't look into.
- **So the default left no failing test out, which says less than it seems.** The case the
  setting exists for, a test that uses what an earlier one read, didn't come up in either
  project. It does in Pitstop's own tests: a test built to do exactly that fails and is left
  out by default, and is picked with the setting.
- **One row of the change lists turned out to be this rule at work.** The changelog entry in
  RuboCop's list at the top of this page was meant to be well formed, and isn't: it links to
  the wrong site. Before this rule Pitstop ran nothing for it, and the run passed. Now it runs
  the changelog spec, which fails on that entry.

## What recording costs

`pitstop record` runs the whole suite with Ruby's coverage on, and reads the coverage after every
test. That is slower than a plain run:

<!-- recording -->
|  | Tests | Whole suite | `pitstop record` | Cost | Map file |
|---|---|---|---|---|---|
| Fizzy | 2,708 | 24.7 s | 45.2 s | 1.83× | 460 KB |
| RuboCop | 36,505 | 219 s | 331 s | 1.51× | 3,579 KB |
| Dead Heat | 95 | 12.2 s | 15.9 s | 1.31× | 100 KB |
<!-- /recording -->

- **Between 1.3 and 1.8 times a plain run.**
- **Noting names and file reads costs little.** The recorder used to note only the lines each
  test ran. It now also notes the method names there are (for added methods) and the files
  tests read. On Fizzy, the three versions timed in turn, four times each, next to a plain
  run: 39.6 s, 40.5 s and 41.6 s at best, where the plain run's best was 24.5 s. That is 1.61,
  1.65 and 1.70 times. (The table's 1.83 is the middle of three timings from another session
  that day.)
- **RuboCop only stays at 1.5 because Pitstop changes how it records.** RuboCop's tests take a few
  milliseconds each, and reading the coverage after each of 36,505 tests made recording several
  times slower than a plain run when that was tried. Pitstop notices when reading costs more than
  half the tests' own time and switches to reading once per test file. The price is a coarser map: a changed line then picks every test
  in the test files that ran it, not just the tests that did.
- **The map is small:** 0.5 MB for Fizzy, 3.6 MB for RuboCop.

## In CI

"Faster CI" and "faster tests" are the same measurement with four differences.

**1. Only the test step shrinks.** Checking out the code, installing gems and preparing the
database take as long as before. These are the two projects' own public CI jobs, as they ran in
November 2026:

| Project's own CI job | Whole job | Of which, the test step Pitstop could shorten |
|---|---|---|
| Fizzy, "Tests (SQLite)" | 168 to 216 s | 43 to 56 s (the rest is setup and browser tests) |
| RuboCop, "Spec - ubuntu 4.0" | 88 to 144 s | 81 to 121 s (its suite spread over the runner's processors) |

For Fizzy, a test step five times faster would shorten the job by about a fifth. For RuboCop the
test step is nearly the whole job.

**2. The main branch pays for the map.** Someone has to run `pitstop record`, and it is slower
than a plain run. The simple setup is: pull requests run `pitstop run`, the main branch runs
`pitstop record` in place of its plain test run. Then the question is how many times a pull
request's tests run before it merges, because every one of those runs saves time and the one
recording costs time. With the averages from the replays above:

<!-- ci -->
| Test runs on a pull request before it merges | Fizzy | RuboCop |
|---|---|---|
| 1 | 43.1 s → 53.0 s (23% more) | 6.5 min → 7.4 min (14% more) |
| 2 | 64.7 s → 66.6 s (3% more) | 9.7 min → 9.9 min (2% more) |
| 3 | 86.2 s → 80.2 s (7% less) | 13.0 min → 12.5 min (4% less) |
| 5 | 2.2 min → 1.8 min (17% less) | 19.5 min → 17.5 min (10% less) |
| 10 | 4.0 min → 2.9 min (26% less) | 35.7 min → 30.1 min (16% less) |
<!-- /ci -->

How to read it: the first number is the test time one merged pull request costs today (each of
its runs, plus the run on the main branch), the second is the same with Pitstop.

- **A pull request whose tests run once comes out behind:** the recording costs more than that
  run saves.
- **Both projects are ahead from the third run.**
- **The more often a pull request is pushed to, the closer the saving gets** to what the replay
  showed.
- The recording is counted at its cost from the table above (1.83 times a plain run on Fizzy,
  1.51 on RuboCop), which was the slower of the two measurements for Fizzy.

So the claim these numbers support is about the test step of pull requests that get several
pushes, not "CI is N times faster".

**3. The map has to be fresh.** It is tempting to record less often (nightly, say) and spread the
cost over a day's merges. A pull request then also runs the tests of everything the main branch
changed since the recording. That stays correct, but this is what it does to the selection.
No tests were run for this table: it asks Pitstop what it would pick at each replayed commit
with an older map, and adds up the picked tests' share of the suite's test time. (Fizzy has one
commit more here than in the replay: its Ruby upgrade couldn't be timed, but it can be asked
about.)

<!-- stale -->
| The map is from | Fizzy: ran everything at | Fizzy: test time picked, on average | RuboCop: ran everything at | RuboCop: test time picked, on average |
|---|---|---|---|---|
| the commit before (recorded at every commit) | 16 of 29 commits | 56% | 5 of 8 commits | 76% |
| 2 commits before | 23 of 28 commits | 83% | 6 of 7 commits | 91% |
| 3 commits before | 25 of 27 commits | 93% | 6 of 6 commits | 100% |
| 5 commits before | 25 of 25 commits | 100% | 4 of 4 commits | 100% |
| 10 commits before | 21 of 21 commits | 100% | - | - |
<!-- /stale -->

The map goes stale fast. A commit that runs everything, anywhere between the recording and the
pull request, runs everything for the pull request too. On Fizzy a map from two commits back
ran everything at 23 of 28 commits; on RuboCop at 6 of 7. Record at every merge, or the map is
worth little.

**4. Picking is not the cost.** Reading the map and deciding what to run took 0.2 s on Fizzy and
0.4 s on RuboCop's 36,505-test map.

## Did it miss anything?

Speed is only worth having if a failing test is never skipped. Three checks:

**Planted bugs.** Small bugs were planted one at a time, on a line that ran while the map was
recorded, and `pitstop run` was run for each:

- **Inside methods:** `==` for `!=`, `&&` for `||`, `if` for `unless`, `true` for `false` and
  the like, each in a different method. If `pitstop run` passed, the whole suite ran, to see
  whether any test catches the bug at all.
- **Outside methods**, in code that runs when a file loads: a constant's value changed, a
  setting flipped (`presence: true`), a line taken out (`validates ...`, `include ...`,
  `before_action ...`). Here the whole suite ran every time, and every test it failed had to be
  among the ones `pitstop run` picked. A run that fails thanks to one picked test while another
  failing test was left out doesn't count as caught.

<!-- planted-bugs -->
| Bugs planted | How many | Caught by no test | Caught by the whole suite | ... of those, caught by `pitstop run` | Failing tests left out |
|---|---|---|---|---|---|
| Fizzy, inside methods | 40 | 4 | 36 | 36 of 36 | not counted |
| Fizzy, outside methods | 40 | 17 | 23 | 23 of 23 | 0 of 6,761 |
| RuboCop, inside methods | 12 | 1 | 11 | 11 of 11 | not counted |
<!-- /planted-bugs -->

Inside methods: of 40 bugs planted in Fizzy, the whole suite catches 36, and the tests Pitstop
picked caught all 36. It picked between 7 and 801 of the 2,708 tests, and for two bugs it ran
everything. 23 of the 36 showed up as a failing run within 5 seconds, and 32 within 10, against
20 seconds for the whole suite. One bug made a test hang; the run's ten-minute limit counted
that as a failure. Of 12 planted in RuboCop, the whole suite catches 11, and the picked tests
caught all 11. (These two rows were measured before the fix below, which only makes Pitstop
pick more.)

Outside methods: of 40 planted in Fizzy, the whole suite catches 23. Pitstop ran everything for
each, so all 23 were caught and none of the 6,761 tests they broke was left out. Before the
fix, 6 of those 23 had failing tests left out, and for one of the six `pitstop run` passed.

The bugs no test catches are gaps in the projects' own tests. The whole suite passes with them
too, so they say nothing about Pitstop.

**Real commits.** Every replayed commit was also run whole, so a test that started failing at a
commit and wasn't picked would have shown up. None did, but that says little: no test started
failing at any of these commits, because both projects keep their main branch passing. The
planted bugs are the check that counts.

**Every run checks itself.** `pitstop run` counts the tests that ran against the tests it picked
and fails if any is missing.

**Four bugs in Pitstop turned up while this page was being measured**, all fixed, each with a
test:

- **A failing test could be skipped.** A change outside any method (a constant, a `validates`)
  picked "every test that ran the file". That code runs when the file loads, before the tests,
  so a test that depends on it needn't have run a line of the file: a constant in one file read
  by a method in another picked no test at all, and `pitstop run` passed while the whole suite
  failed. An added method, a new Ruby file and a one-line method had the same hole. They all run
  everything now. (pytest-testmon has the same gap: its
  [issue 191](https://github.com/tarpas/pytest-testmon/issues/191), which its maintainer calls
  "quite a fundamental limitation".)
- Fizzy has two test files that open the same test class. Pitstop filed one of their tests under
  the wrong file, and a run stopped with "1 selected test didn't run". The check above did its
  job: the run failed instead of passing with a test missing.
- One replayed commit changed a browser test under `test/system`. `bin/rails test` leaves that
  folder out, but Pitstop named the changed file, so it ran two browser tests the whole suite
  never runs, and they failed for want of a browser. Pitstop now leaves such a file out and says
  so. (That commit was replayed again after the fix.)
- A project's own `global` pattern lost to the built-in rule that docs are ignored, so the advice
  at the end of this section would have done nothing. A project's own patterns now come first.

**What can still be missed.** Pitstop follows Ruby code, the templates Ruby's coverage sees,
and the files Ruby code opens while the tests run. For any other file it runs everything, with
four kinds it assumes can't break a test unless a test read them: docs, CI and deploy
settings, the scripts in `bin/` and `script/`, and files only a browser uses (CSS, JavaScript,
images). What that leaves:

- **A test that uses what an earlier test read**, without opening the file itself. Left out by
  default, picked with `tests_after_readers: true` (see
  [Files that tests read](#files-that-tests-read)).
- **A file opened by something that isn't Ruby:** a test that runs `git ls-files` or `cat`, or
  a gem that reads files in its own C code. Pitstop doesn't see those reads.
- **Tests that drive a browser.** They depend on CSS and JavaScript in ways no read shows.
  Fizzy's browser tests are a separate command, and weren't recorded or measured here. Run
  tests like that whole.
- **A new method reached by a name built at run time** (`public_send("on_#{kind}")`), when
  that name appears nowhere in the project. See
  [the README](../README.md#code-that-runs-when-a-file-loads).

For a file of the second kind, list it under `global` in `.pitstop.yml`, so a change to it
runs everything. And whatever a pull request's run left out is run when the map is recorded
again at the merge: that run is the whole suite.

## What other tools publish

Most tools of this kind publish no measurements at all. Where there are numbers, this page
follows the same method:

- **[Ekstazi](https://users.ece.utexas.edu/~gligoric/papers/GligoricETAL15Ekstazi.pdf)** (Java,
  2015) is the study most others copy. It replayed 615 revisions of 32 projects, 20 or so per
  project, and for each revision timed the developers' own test command three ways: everything,
  the selection, and the selection while collecting. Running the selection took 53% of running
  everything on average, 68% with collecting included, and it was slower than running everything
  on some suites shorter than a minute.
- **[STARTS](https://www.cs.cornell.edu/~legunsen/pubs/LegunsenETAL17STARTS.pdf)** (Java, 2017)
  picked 35% of tests and took 81% of the time of running everything.
- **[pytest-testmon](https://testmon.org/)** (Python) and
  **[Crystalball](https://github.com/toptal/crystalball)** (Ruby) publish no numbers.
- **Tools that predict** which tests are likely to fail (rather than work out which can be
  affected) report how many real failures the prediction would have caught, because they are
  expected to miss some. Pitstop is not that kind: when it can't tell, it runs everything.

Like Ekstazi, a selection on a short suite can be slower than the suite (Dead Heat above).

## What these numbers don't show

- **Other machines.** Every time here comes from one desktop. The shares of tests picked don't
  depend on the machine; the seconds do.
- **Other projects.** Three projects, and only two of them are other people's. How much a
  project gains depends on how its tests are built: many small tests gain a lot, a few broad
  slow tests gain little.
- **A long history.** The replays cover 29 Fizzy commits and 8 RuboCop commits, enough to see
  the mix, not enough for a precise average.
- **RuboCop's own parallel runner.** Its CI spreads the suite over several processes with
  `rake spec`. Both sides here run `bundle exec rspec` in one process.

## Run it yourself

Everything runs in the containers from `compose.yaml` (the scripts delete `/work` and change
git's global settings, so they refuse to run anywhere else). Clone the projects into
`bench/apps/` first.

```sh
# one change at a time, three rounds, numbers into bench/results/
docker run --rm --memory=8g -e ROUNDS=3 -e RECORDS=3 -e OUT=/pitstop/bench/results/fizzy-changes.json \
  -v "$PWD:/pitstop" -v pitstop_bundle4:/usr/local/bundle pitstop-dev4 sh /pitstop/bench/e2e/fizzy.sh

# the last 6 commits, one by one, keeping each commit's map
docker run --rm --memory=8g -e OUT=/pitstop/bench/results/fizzy-replay.jsonl -e MAPS=/pitstop/bench/out/maps/fizzy \
  -v "$PWD:/pitstop" -v pitstop_bundle4:/usr/local/bundle pitstop-dev4 sh /pitstop/bench/e2e/fizzy.sh replay 6

# the same commits timed once more, from the kept maps (add -e RETIME=1 to the line above)

# 40 planted bugs
docker run --rm --memory=8g -e OUT=/pitstop/bench/results/fizzy-mutants.jsonl \
  -v "$PWD:/pitstop" -v pitstop_bundle4:/usr/local/bundle pitstop-dev4 sh /pitstop/bench/e2e/fizzy.sh mutants 40

# 40 bugs planted outside methods, with every failing test checked (add -e WHERE=outside to the line above)

# 40 changes to files that tests read (add -e WHERE=read, and another results file)

# after a change to what Pitstop picks: ask it again at each replayed commit (no tests run)
ruby bench/e2e/reselect.rb bench/apps/fizzy bench/out/maps/fizzy bench/results/fizzy-replay.jsonl --save

# the same with `tests_after_readers: true`, on a copy of the results (AFTER_READERS=1 also works with -e RETIME=1)
AFTER_READERS=1 ruby bench/e2e/reselect.rb bench/apps/rubocop bench/out/maps/rubocop bench/results/rubocop-replay-after-readers.jsonl --save

# what older maps would pick (no tests run, no container needed)
ruby bench/e2e/stale.rb bench/apps/fizzy bench/out/maps/fizzy bench/results/fizzy-replay.jsonl bench/results/fizzy-stale.json

ruby bench/report.rb   # rewrites the tables on this page from bench/results/
```

`rubocop.sh` takes the same forms. The numbers behind every table are in `bench/results/`.

Fizzy runs only on the Ruby version in its `.ruby-version`. Its 24 commits before the move to
Ruby 4.0.10 were replayed in an image built from `docker/dev.Dockerfile` with
`RUBY_VERSION=4.0.9`, with `-e UNTIL=<the last commit on that Ruby>`.
