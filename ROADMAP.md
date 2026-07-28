# Roadmap

Where zcontainer is heading, and why in that order. Nothing here is a promise;
it is a record of what looks worth doing next and what it would cost.

## Where it stands (v0.0.1)

Two front ends — a TUI and a browser page — over one shared data layer
(`cli.zig`). Both can list containers, stacks, images, volumes, networks and
live stats, and can start, stop, kill, delete and prune. The TUI additionally
follows logs and opens a shell.

Everything is read through `container --format json` and acted on by shelling
out. There is no daemon protocol, no cache and no state on disk.

## Done: a fake `container` — 32 tests

This was the first priority, and it has landed.

`cli.zig` is now split so that running a command and decoding its output are
separate: every `listX` has a `parseX` counterpart taking text. Fixtures in
`src/testdata/` cover shapes this machine has never produced — a **stopped**
container, one with no `status` key at all, an untagged image, a registry
reference with a port, an empty list, blank output and malformed JSON.

`test/fake-container.zig` stands in for the real CLI, serving those fixtures
and appending its argv to a log. `cli.exe` is a variable so tests can point at
it. That covers what unit tests structurally cannot:

- `delete` really passes `--force`, `prune` really targets the current tab, and
  a stack action really touches every member and nothing outside it
- a refresh issues no mutating command at all
- a missing binary is reported rather than fatal (`cli.exe` aimed at a path
  that does not exist)

The `--force` assertion was checked by mutation: removing the flag makes the
test fail, so it is load-bearing rather than decorative.

Two of these tests failed on first run — both were wrong expectations about
sort order in the test, not bugs. That ordering is now pinned.

The web front end got the same treatment. `std.http.Server` works on a
Reader/Writer pair rather than a socket, so a whole request can be driven
through the real routing by feeding it bytes. The checks that previously
existed only as `curl` commands in a terminal are now tests: no token, wrong
token, a right-length wrong token, a query-string token where only a header
will do, a foreign `Origin`, `GET` on an action, an unknown action, a missing
target, an unknown path — and that a state response never contains a container
environment.

**50 tests, no daemon required.**

## Done: CI

`.github/workflows/ci.yml` builds and tests on macOS and Linux, checks
formatting, and fails if the tests leave a stray file behind.

Linux is compile-only in spirit — Apple's `container` runs nowhere else — but
it earned its place immediately: it caught that `std.c.ioctl` needs libc named
explicitly, which macOS had been hiding by always linking it.

## Done: sort and filter (TUI)

`/` filters the current tab, `o` steps the sort column and `O` reverses it.

Rows now reach the screen through a per-tab index list rather than being read
straight out of the data, so the cursor always means the row the user is
looking at — an action after filtering targets what is shown, which a test
pins down. Filters are per tab: a single shared one emptied the Images tab
because the container list had been narrowed, which is not what "filter the
current tab" leads anyone to expect. Numeric columns sort as numbers, so
memory does not put "1.0 GB" before "256 MB".

## v0.1 — the rest

**Bulk selection.** Space to mark rows, then act on the marks. The stack
actions already prove the tally-reporting pattern.

**Sort and filter in the browser.** The TUI has it; the web page does not.

**Ports column and per-container detail in the browser.** The web page shows
less than the TUI does; published ports and mounts are already in the payload
and simply are not rendered.

**Copy files (`container cp`).** One command, no streaming, immediately useful.

## v0.2 — streaming in the browser

`std.http.Server` has `respondWebSocket`, so this needs no new dependency —
I checked. Two features fall out of the same machinery:

**Live log follow**, matching what the TUI already does.

**A shell in the browser**, running `container exec -it` with the pty bridged
over the socket. This is the largest single piece of work on the list and the
one most likely to be fiddly: terminal resizing, escape handling, and a
front-end terminal emulator that has to be written by hand or vendored, which
would break the zero-dependency property the web front end currently has.
Worth weighing against simply telling people to use the TUI.

## v0.3 — creating things

Today zcontainer manages containers that already exist. This is the biggest
functional gap.

**Run a container.** `container run` takes about fifty distinct options. A form
exposing all of them would be worse than the CLI. A useful subset — image, name, ports, env,
volumes, cpus, memory, detach, entrypoint — covers most day-to-day use, with
an escape hatch showing the exact command it will run so nothing is hidden.

**Pull an image**, with progress. Needs the streaming work from v0.2.

**Build from a Dockerfile.** Same streaming requirement, plus build context
selection. `container builder` also has its own lifecycle worth surfacing —
the builder shows up today as just another container.

## Foundations, alongside the above

**Distributed binaries.** Releases carry no artifacts today, because a
`-Dcpu=native` build is tuned to the machine that produced it. A `baseline`
build attached to the release would let people skip installing Zig.

**Wide characters.** Every glyph is counted as one column. A container named in
CJK, or an emoji in a log line, will misalign a row. `cli.zig` is already safe;
this is `ui.zig` arithmetic only.

**Split `app.zig`.** It is past 1200 lines and now holds state, refresh, stack
grouping, CPU sampling, pager and actions. Splitting follows naturally the
next time one of those grows.

**Config file.** Refresh interval, default tab, the shell used by `e`, whether
delete implies `--force`. All hard-coded today.

## Deliberately not planned

**Registry credentials in any UI.** `container registry login` handles
passwords and tokens. Those belong in the terminal where the CLI can use the
keychain, not in a browser form or a TUI prompt that has to hold them in
process memory. zcontainer will show *which* registries are logged in, and
nothing more.

**Remote or multi-host management.** The web server binds loopback and has no
TLS by design. Exposing it to a network would mean auth, transport security and
an audit trail — a different product.

**A daemon protocol.** Shelling out to `container` keeps zcontainer honest: the
tool shows what the CLI reports, and every action is one the user could have
typed. Talking to the daemon directly would be faster and much easier to get
subtly wrong.

## Constraints worth remembering

- `container inspect` returns the same shape the list endpoint already
  provides, so a detail view needs no extra call — the TUI builds its detail
  sheets from data it already has.
- `container stats` gives cumulative CPU time and no ordering guarantee. Both
  are already handled (deltas, and a stable sort), and both will bite again in
  any new view that consumes it.
- `container system dns` requires administrator rights, so anything built on it
  has to degrade gracefully rather than assume it can run.
