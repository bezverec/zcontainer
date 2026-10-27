# Roadmap

Where zcontainer is heading, and why in that order. Nothing here is a promise;
it is a record of what looks worth doing next and what it would cost.

For what has already shipped, see the
[releases](https://github.com/bezverec/zcontainer/releases) — this file is
about what has not.

## Where it stands (v0.1.0)

Two front ends, a TUI and a browser page, over one shared data layer
(`cli.zig`). Both list containers, stacks, images, volumes, networks and live
stats; both start, stop, kill, delete, prune and copy files; both filter and
sort per tab. The TUI additionally follows logs, marks rows for bulk actions,
and opens a shell.

Everything is read through `container --format json` and acted on by shelling
out. There is no daemon protocol, no cache and no state on disk.

72 tests, none of which need a container daemon, and CI on macOS and Linux.

## v0.2 — streaming in the browser

`std.http.Server` has `respondWebSocket`, so this needs no new dependency.
Two features fall out of the same machinery:

**Live log follow**, matching what the TUI already does.

**A shell in the browser**, running `container exec -it` with the pty bridged
over the socket. This is the largest single piece of work on the list and the
one most likely to be fiddly: terminal resizing, escape handling, and a
front-end terminal emulator that has to be written by hand or vendored — which
would cost the web front end its zero-dependency property. Worth weighing
against simply telling people to use the TUI, which already does this well.

## v0.3 — creating things

zcontainer manages containers that already exist. This is the biggest
functional gap, and the single-line prompt the copy feature needed is the
groundwork for it.

**Run a container.** `container run` takes about fifty distinct options. A form
exposing all of them would be worse than the CLI. A useful subset — image,
name, ports, env, volumes, cpus, memory, detach, entrypoint — covers most
day-to-day use, with an escape hatch showing the exact command it will run so
nothing is hidden.

**Pull an image**, with progress. Needs the streaming work from v0.2.

**Build from a Dockerfile.** Same streaming requirement, plus build context
selection. `container builder` has its own lifecycle worth surfacing too; the
builder shows up today as just another container.

## Foundations

**Distributed binaries.** Releases carry no artifacts, because a
`-Dcpu=native` build is tuned to the machine that produced it and could fault
on an older CPU. A `baseline` build attached to a release would let people skip
installing Zig.

**Wide characters.** Every glyph counts as one column. A container named in CJK,
or an emoji in a log line, will misalign a row. `cli.zig` is already safe; this
is `ui.zig` arithmetic only.

**Split `app.zig`.** It is past 1700 lines of code before its 600 lines of
tests, and holds state, refresh, filtering, sorting, marks, stack grouping, CPU
sampling, the pager, prompts and actions. Splitting follows naturally the next
time one of those grows.

**Config file.** Refresh interval, default tab, the shell used by `e`, whether
delete implies `--force`. All hard-coded.

## How it is tested

Worth stating because it shapes what changes are safe to make.

`test/fake-container.zig` stands in for the CLI: it serves the fixtures in
`src/testdata/` and records the argv it was called with. That is what lets a
test assert that `delete` really passes `--force`, that prune targets the
current tab, and that a stack or bulk action touches every member and nothing
outside it — mistakes no unit test would catch. `cli.exe` is a variable purely
so tests can point at it.

The fixtures deliberately cover shapes a healthy machine never produces: a
stopped container, one with no `status` key at all, an untagged image, a
registry reference with a port, an empty list, blank output, malformed JSON.
Real bugs have come from the other direction too — an image whose creation date
is the Unix epoch showed up only when running against a real daemon — so
neither fixtures nor live runs are sufficient alone.

Linux CI cannot run this program, since Apple's `container` exists nowhere
else, but it earns its runner by catching portability slips: it found that
`std.c.ioctl` needs libc named explicitly, which macOS hides by always linking
it.

## Deliberately not planned

**Registry credentials in any UI.** `container registry login` handles
passwords and tokens. Those belong in the terminal where the CLI can use the
keychain, not in a browser form or a TUI prompt that has to hold them in
process memory. zcontainer will show *which* registries are logged in, and
nothing more.

**Remote or multi-host management.** The web server binds loopback and has no
TLS by design. Exposing it to a network would mean auth, transport security and
an audit trail — a different product.

**A daemon protocol.** Shelling out keeps zcontainer honest: the tool shows what
the CLI reports, and every action is one the user could have typed. Talking to
the daemon directly would be faster and much easier to get subtly wrong.

## Constraints worth remembering

- `container inspect` returns the same shape the list endpoint already
  provides, so a detail view needs no extra call — both front ends build their
  detail sheets from data they already have.
- `container stats` gives cumulative CPU time and no ordering guarantee. Both
  are handled (deltas, and a stable sort), and both will bite again in any new
  view that consumes it.
- `container stats --no-stream` takes two samples two seconds apart whenever a
  container runs, so every call costs two seconds. Both front ends ask for
  stats only while the Stats tab is open; anything else that wants them must
  not sit on the regular refresh path.
- `container copy` requires a running container; it fails on a stopped one.
- zcontainer issues no registry operation, which is why 1.3.0 removing
  `--scheme auto` passed straight through. Adding image pull would put the
  project back in the path of those changes.
- `container system dns` requires administrator rights, so anything built on it
  has to degrade gracefully rather than assume it can run.
- The JSON shapes above are unchanged across CLI 1.0.0, 1.2.0, 1.2.1, 1.3.0
  and 1.6.1, but nothing guarantees that holds. What did change by 1.6.1 is
  outside the JSON: `system status` grew into a wider FIELD/VALUE table (now
  parsed by row name) and slashes in JSON strings are no longer escaped. The fixtures would keep passing while the real
  thing broke, so a version bump is worth a manual shape check against a live
  daemon — reading the upstream diff is not enough on its own.
- Unknown fields are ignored when decoding, so a newer CLI adding keys cannot
  break the parsers. That is what makes those upgrades cheap, and it now has a
  test rather than being a setting nobody checks.
