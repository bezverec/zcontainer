# zcontainer

A terminal UI for Apple's [`container`](https://github.com/apple/container)
CLI on macOS, written in Zig.

```
   ╭───────╮╭───────╮╭───────╮
   │▪ ▪ ▪ ▪││▪ ▪ ▪ ▪││▪ ▪ ▪ ▪│
   ╰───────╯╰───────╯╰───────╯
  ┌─┐┌─┐┌─┐┌┐┌┌┬┐┌─┐┬┌┐┌┌─┐┬─┐
  ┌─┘│  │ ││││ │ ├─┤│││││├┤ ├┬┘
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

 j/k move  s start  S stop  K kill  d delete  l logs  e shell  ↵ details  ? help
```

## Requirements

- macOS with the Apple `container` CLI installed and on `PATH`
- Zig 0.16.0

## Build and run

```bash
zig build run
```

Or build an optimised binary:

```bash
zig build -Doptimize=ReleaseSafe
```

The executable lands in `zig-out/bin/zcontainer`.

```bash
zig build test
```

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

| Key | Action |
| --- | --- |
| `j` / `k`, arrows | Move the cursor |
| `g` / `G` | Jump to first / last row |
| `ctrl-d` / `ctrl-u` | Half page down / up |
| `1` … `6` | Select tab directly |
| `tab` / `shift-tab` | Cycle tabs |
| `enter` | Details for the selected row (stack members, on Stacks) |
| `l` | Show the last 1000 log lines |
| `f` | In the log view: start or stop following |
| `e` | Open a shell (`/bin/sh`) in the selected container |
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

Following a log runs `container logs --follow` as a child process, drained
without blocking between key presses. Scrolling back detaches from the tail;
returning to the bottom (or `G`) re-attaches. The retained buffer is capped at
1 MB, dropping whole lines from the front.

Opening a shell hands the terminal to the child: zcontainer leaves the
alternate screen and raw mode, runs `container exec --interactive --tty`, and
restores the display when the shell exits.

## Layout of the source

| File | Contents |
| --- | --- |
| `src/main.zig` | Entry point, event loop, key bindings, terminal handover |
| `src/app.zig` | State, refresh, stack grouping, CPU sampling, actions |
| `src/ui.zig` | Frame rendering, column layout, logo |
| `src/cli.zig` | `container` invocation and JSON decoding |
| `src/term.zig` | Raw mode, alternate screen, key decoding |

`app.zig` never touches the terminal and `ui.zig` never runs a command, so the
rendering can be tested against plain buffers.

Two invariants are pinned by tests because breaking them corrupts the whole
display rather than one cell:

- A rendered row must be exactly as wide as its column layout claims, at every
  width from 40 upward. An overflowing row wraps and shifts every later frame.
- Text drawn into a cell must be stripped of control characters. Log output is
  untrusted: a tab would desynchronise the column accounting, and a raw escape
  sequence could repaint the screen.

## Known limitations

- Actions run synchronously. `container stop` waits for the container to shut
  down, and the UI is unresponsive until it returns; the status line shows what
  is running. There is no background job queue.
- The shell is hard-coded to `/bin/sh`, the one interpreter essentially every
  Linux image ships. Images without it cannot be entered with `e`.
- Stack membership is inferred, not declared. Unrelated containers that happen
  to share a name prefix will be grouped together.
- No create, run, pull, build or port editing. Use the CLI for those.
- Column values are assumed to be roughly ASCII. Wide (CJK) or combining
  characters are counted as one column each and will misalign a row.
- Only the first network of a container is shown in the table.

## License

GPL-3.0. See [LICENSE](LICENSE).
