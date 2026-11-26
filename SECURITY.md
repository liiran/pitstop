# Security

## Reporting a problem

Please report security problems privately, through GitHub: on this repository's **Security** tab,
choose **Report a vulnerability**. Please don't open a public issue for them.

Say what you did, what happened, and what you expected. A small project that shows the problem
helps most.

## What Pitstop trusts

Pitstop runs your project's tests, so it trusts the project the same way `rake test` does: test
files, the `Rakefile` and the test command in `.pitstop.yml` are code that runs on your machine.
Only run `pitstop record` and `pitstop run` on projects whose tests you would run anyway.

These are treated as data, never as code:

| Input | How it's handled |
|---|---|
| `.pitstop/map.json.gz` | Parsed as JSON and checked: a full commit id, file paths that stay inside the project, numbers where numbers belong. Anything else is refused. |
| `.pitstop.yml` | Parsed as plain YAML: no Ruby objects, no aliases. Unknown settings are refused. |
| File and test names | Passed to git and to the test command as single arguments, never through a shell. Shown on the terminal with control characters written out (`\e`), not sent. |

`pitstop list` runs no project code at all: it reads the map and the settings, and asks git
what changed.

## What counts as a security problem

- Pitstop running a command, or loading a file, that the project's test command wouldn't.
- Pitstop writing outside the project's `.pitstop/` folder. (A `.pitstop` that is a link to
  another place is refused.)
- A map or settings file making Pitstop do anything other than pick tests.
- A map holding something the README says it doesn't: a path from outside the project, what a
  file says, an environment variable.
- Recording changing what a test does or sees, beyond what the README lists.
- Pitstop sending anything over the network (it has no code that does).

A wrong pick (a test that should have run and didn't) is a bug, not a security problem, unless
someone can cause it on purpose from outside the project. Please report those as ordinary issues.

## Using a map from somewhere else

The map decides which tests are skipped. In CI, build it from your main branch and hand it to
other jobs yourself (a cache or an artifact). Don't take a map from the change being tested: its
author could give you one that skips the tests their change breaks.
