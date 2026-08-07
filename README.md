# zcontainer

A terminal UI for Apple's [`container`](https://github.com/apple/container)
CLI on macOS, written in Zig.

```
  ┌─┐┌─┐┌─┐┌┐┌┌┬┐┌─┐┬┌┐┌┌─┐┬─┐
  ┌─┘│  │ ││││ │ ├─┤││││├┤ ├┬┘
  └─┘└─┘└─┘┘└┘ ┴ ┴ ┴┴┘└┘└─┘┴└─
    a TUI for Apple container
```

It wraps the `container` command rather than talking to the daemon directly:
every list is read with `--format json` and every action shells out to the same
subcommand you would type by hand. Nothing is cached and nothing is written to
disk, so what you see is whatever `container` reports.

```
 zcontainer  3/3 running                                             system: running
 1 Containers 3  2 Stacks 2  3 Images 3  4 Volumes 1  5 Networks 1  6 Stats 3
NAME                  STATE       IMAGE                         IP              CPU  MEMORY
buildkit              running     ghcr.io/apple/container-bui…  192.168.64.124  2    2.0 GB
shop-api              running     shop-api:latest               192.168.64.133  4    1.0 GB
shop-db               running     docker.io/library/postgres:…  192.168.64.2    4    1.0 GB

 ↑↓ j/k move  space mark  ↵ details  / filter  o sort  s start  S stop      q quit
```

## Requirements

- macOS with the Apple `container` CLI installed and on `PATH`
  (verified against 1.0.0, 1.2.0 and 1.2.1; the JSON shapes it reads are the
  same in all three)
- Zig 0.16.0

## Installing Zig

```bash
brew install zig
```

That currently gives 0.16.0, which is what this needs.

Be aware that Homebrew tracks the latest stable Zig, so once 0.17 lands the
same command will give you that instead — and Zig still changes its standard
library freely between releases, enough that a version bump is a porting job
rather than a recompile. If you would rather pin the version, take the archive
straight from [ziglang.org/download](https://ziglang.org/download/) and put it
on your `PATH`:

```bash
curl -LO https://ziglang.org/download/0.16.0/zig-aarch64-macos-0.16.0.tar.xz
tar xf zig-aarch64-macos-0.16.0.tar.xz
sudo mv zig-aarch64-macos-0.16.0 /usr/local/zig-0.16.0
sudo ln -sf /usr/local/zig-0.16.0/zig /usr/local/bin/zig
```

Zig needs nothing else installed; the archive is self-contained.

## Build and run

```bash
zig build run
```

Or build an optimised binary tuned for the machine it is built on:

```bash
zig build -Doptimize=ReleaseFast -Dcpu=native
```

`-Dcpu=native` compiles for the host CPU's instruction set extensions rather
than the architecture baseline. Do not expect a speedup: zcontainer spends
nearly all its time waiting on subprocesses and terminal writes, and has no
compute-bound path to accelerate. On Apple silicon the native and baseline
binaries come out within a few bytes of each other.

ReleaseSafe keeps the bounds and overflow checks, which is worth ~70 KB for a
tool that parses JSON and log output it does not control:

```bash
zig build -Doptimize=ReleaseSafe -Dcpu=native
```

Either way the executable lands in `zig-out/bin/zcontainer`.

```bash
zig build test
```

## Install

zcontainer is a single self-contained binary — installing it means putting
that one file somewhere on your `PATH`.

Into a user-owned directory, no `sudo` needed:

```bash
zig build -Doptimize=ReleaseFast -Dcpu=native --prefix ~/.local
```

That writes `~/.local/bin/zcontainer`. If `~/.local/bin` is not on your `PATH`
yet, add it:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
```

System-wide instead, which needs `sudo` because `/usr/local/bin` is
root-owned:

```bash
zig build -Doptimize=ReleaseFast -Dcpu=native
sudo install -m 755 zig-out/bin/zcontainer /usr/local/bin/
```

Then, from anywhere:

```bash
zcontainer
```

Uninstalling is deleting that one file; zcontainer writes no config, cache or
state of its own.

## Browser interface

`zcontainer-web` serves the same data over HTTP for a browser, sharing
`cli.zig` with the TUI and adding only transport.

```bash
zig build web
# or, once installed
zcontainer-web
```

It prints a URL carrying a token; open that. `--port` picks a different port,
`0` picks a free one.

The page lists the same six views, refreshes every three seconds, and offers
start, stop, kill, delete, prune, copy and a log viewer. It filters and sorts like
the TUI: type in the box to narrow the current tab, click a column header to
sort by it, click again to reverse and a third time to return to the server's
order. Clicking a row opens its details — the same sheet the TUI shows on
`enter`, including published ports and mounts.

Container environment variables are deliberately **not** served — they
routinely carry credentials, and a browser is a leakier place for them than a
terminal.

### Why the token

The server can start, stop and delete containers, so it is locked down three
ways:

- It binds `127.0.0.1` only, so nothing off-machine can reach it.
- Every request must present a random token minted at startup. A loopback port
  is **not** an origin boundary — any page open in the browser can POST to it —
  and the token is the part a cross-site request cannot guess. API calls carry
  it in a header, which a cross-site form post cannot set.
- Requests carrying an `Origin` header from anywhere else are refused, which
  also blocks DNS rebinding.

The token is compared in constant time and changes on every start.

## Command line

zcontainer takes no arguments in normal use — everything happens inside the
interface. Two flags print and exit:

```bash
zcontainer --version   # or -v
zcontainer --help      # or -h
```

The version comes from `build.zig.zon`, so the manifest, `--version` and the
header inside the interface cannot drift apart.

## Tabs

| Tab | Shows |
| --- | --- |
| Containers | Every container with state, image, IP and resource limits |
| Stacks | Containers grouped into related sets (see below) |
| Images | Local images with tag, digest, architecture and age |
| Volumes | Named volumes with driver, format, size and host path |
| Networks | Networks with mode, subnet and gateway |
| Stats | Live CPU %, memory, network and block I/O, process count |

### Stacks

Apple's `container` has no compose-style project concept, so membership is
inferred:

1. A label naming the stack, if the container carries one —
   `com.docker.compose.project`, `io.podman.compose.project`, `zcontainer.stack`
   or `com.apple.container.plugin`.
2. Otherwise a name prefix up to the first `-` or `_`, but only when at least
   one other container shares it, so `shop-api` and `shop-db` form stack
   `shop`.
3. Otherwise the container is listed under `(standalone)`.

`s`, `S` and `d` on a stack apply to every member and report a tally rather
than a single result.

### Stats

`container stats` reports cumulative CPU time, so a percentage only appears
once there are two samples — the first refresh after opening shows `0.00`.
Values are coloured green, amber or red as they approach the container's limit.
The status line carries the `container system df` summary while this tab is
open.

## Keys

Every list and the log viewer are navigable with the arrow keys as well as the
vi-style keys; `q` quits from anywhere.

| Key | Action |
| --- | --- |
| `↑` / `↓`, `j` / `k` | Move the cursor |
| `←` / `→` | Previous / next tab |
| `page up` / `page down` | Move a screen at a time |
| `home` / `end`, `g` / `G` | Jump to first / last row |
| `ctrl-d` / `ctrl-u` | Half page down / up |
| `1` … `6` | Select tab directly |
| `tab` / `shift-tab` | Cycle tabs |
| `space` | Mark the row; actions then apply to every mark |
| `/` | Filter the current tab; `enter` keeps it, `esc` clears it |
| `o` / `O` | Step the sort column / reverse the direction |
| `enter` | Details for the selected row (stack members, on Stacks) |
| `l` | Show the last 1000 log lines |
| `f` | In the log view: start or stop following |
| `e` | Open a shell (`/bin/sh`) in the selected container |
| `c` | Copy files in or out of the selected container |
| `s` | Start container, or every member of a stack |
| `S` | Stop container, or every member of a stack |
| `K` | Kill container |
| `d` | Delete the selected row, or every member of a stack |
| `P` | Prune what the current tab lists |
| `r` | Refresh now |
| `?` | Help |
| `esc` | Leave details, logs or help |
| `q`, `ctrl-c` | Quit |

Everything except `s` asks for confirmation on the status line; press `y` to go
ahead, `n` or `esc` to cancel. The prune prompt states how much space
`container system df` thinks it can reclaim. Container deletion passes
`--force`, so it also removes running containers once confirmed.

The list reloads by itself every three seconds while it is on screen. Detail,
log and help views hold still so they can be read.

Marking rows with `space` retargets every action key at the marks instead of
the cursor, and a bulk action always confirms — even `start`, which is
unconfirmed for a single row. Marks are held by name, so sorting or reloading
cannot slide them onto a different container. `esc` clears them.

Each tab keeps its own filter and its own sort order, so narrowing the
container list does not empty the Images tab. A filter survives the automatic
reload, and the status line says how many rows it is hiding. Sorting steps
through the columns and then back to the natural order each list arrives in —
running containers first, images by reference. Numeric columns sort as numbers,
so memory orders 256 MB before 1 GB rather than alphabetically.

Following a log runs `container logs --follow` as a child process, drained
without blocking between key presses. Scrolling back detaches from the tail;
returning to the bottom (or `G`) re-attaches. The retained buffer is capped at
1 MB, dropping whole lines from the front.

`c` copies files with `container copy`. One side is a path inside the
container, written `name:/path`; the other is a path on this Mac. The TUI asks
for the two paths in turn, pre-filling the container side from the selected
row; the browser asks for both in one dialog.

Opening a shell hands the terminal to the child: zcontainer leaves the
alternate screen and raw mode, runs `container exec --interactive --tty`, and
restores the display when the shell exits.

## Layout of the source

| File | Contents |
| --- | --- |
| `src/main.zig` | TUI entry point, event loop, key bindings, terminal handover |
| `src/app.zig` | State, refresh, stack grouping, CPU sampling, actions |
| `src/ui.zig` | Frame rendering, column layout, logo |
| `src/cli.zig` | `container` invocation and JSON decoding — shared |
| `src/term.zig` | Raw mode, alternate screen, key decoding |
| `src/web.zig` | HTTP server, token auth, JSON endpoints |
| `src/assets/index.html` | The browser front end, embedded at build time |

`app.zig` never touches the terminal and `ui.zig` never runs a command, so the
rendering can be tested against plain buffers. `cli.zig` knows about neither,
which is why the browser front end reuses it without a single change.

### Tests

```bash
zig build test
```

The suite needs no container daemon. `test/fake-container.zig` stands in for
the CLI: it serves the fixtures in `src/testdata/` and appends every argv it
was called with to a log, so a test can assert which command the program
actually chose to run. `cli.exe` is a variable purely so tests can point at it.

That matters because the mistakes worth catching here are not arithmetic — they
are a `delete` that forgets `--force`, a prune aimed at the wrong tab, or a
stack action reaching a container outside the stack. The fixtures also cover
shapes a healthy machine never produces: a stopped container, one with no
`status` key, an untagged image, an empty list and malformed JSON.

A handful of layout and input invariants are pinned by their own tests,
because breaking any of them corrupts the whole display rather than one cell:

- A rendered row must be exactly as wide as its column layout claims, at every
  width from 40 upward. An overflowing row wraps and shifts every later frame.
- Text drawn into a cell must be stripped of control characters. Log output is
  untrusted: a tab would desynchronise the column accounting, and a raw escape
  sequence could repaint the screen.
- The key hint bar must keep its exit hint at every width, so the way out is
  never the first thing dropped when space runs short.
- Escape must not swallow the keystrokes after it, which on the list view are
  commands.

Each of those was written after the bug it describes, and the first two were
checked by mutation — undo the fix and the test fails — so they are
load-bearing rather than decorative.

## Known limitations

- Actions run synchronously. `container stop` waits for the container to shut
  down, and the UI is unresponsive until it returns; the status line shows what
  is running. There is no background job queue.
- The shell is hard-coded to `/bin/sh`, the one interpreter essentially every
  Linux image ships. Images without it cannot be entered with `e`.
- Stack membership is inferred, not declared. Unrelated containers that happen
  to share a name prefix will be grouped together.
- No create, run, pull, build or port editing. Use the CLI for those.
- `zcontainer-web` handles one request at a time and closes each connection
  after answering it. That is fine for one browser and a local daemon; it is
  not a general-purpose server, and it has no TLS because it never leaves the
  loopback interface.
- The browser front end has no shell and no live log follow — those need a
  terminal and a streaming transport respectively. Use the TUI for them.
- Column values are assumed to be roughly ASCII. Wide (CJK) or combining
  characters are counted as one column each and will misalign a row.
- Only the first network of a container is shown in the table.

## What's next

See [ROADMAP.md](ROADMAP.md). The short version: the next piece of work is a
fake `container` executable for the tests, because nothing currently exercises
this program against the CLI it wraps.

## License

Copyright (C) 2026 Jan Houserek

zcontainer is free software: you can redistribute it and/or modify it under the
terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. It is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE. See the [LICENSE](LICENSE) file for the full terms.

The `LICENSE` file is the GPL-3.0 text verbatim. Its closing appendix, "How to
Apply These Terms to Your New Programs", is an instruction sheet rather than a
form: the `<one line…>` and `<name of author>` placeholders in it describe what
to put at the top of your *source* files, and filling them in stops the file
matching the canonical text, which is how GitHub recognises the licence.
