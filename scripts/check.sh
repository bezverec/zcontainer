#!/usr/bin/env bash
# Runs what CI runs, on this machine. CI is started by hand only, so this is
# the check to run before pushing.
#
# The Linux runner is stood in for by cross-compiling: the binaries and the
# test suite are built for x86_64 and aarch64 Linux, and the tests are run only
# natively. That still catches the slips Linux CI existed for, such as relying
# on libc without naming it.
set -euo pipefail

cd "$(dirname "$0")/.."

step() { printf '\n== %s\n' "$1"; }

# Compared before and after rather than required empty, so the script can be
# run with uncommitted work in the tree.
before="$(git status --porcelain --untracked-files=all)"

step "formatting"
zig fmt --check build.zig src test

step "tests"
zig build test --summary all

for target in x86_64-linux-gnu aarch64-linux-gnu; do
    step "cross-compile for $target"
    zig build -Dtarget="$target"
    zig build test -Dtarget="$target"
done

# Last, so zig-out ends up holding native binaries.
step "release build"
zig build -Doptimize=ReleaseSafe
./zig-out/bin/zcontainer --version
./zig-out/bin/zcontainer-web --version

step "working tree"
after="$(git status --porcelain --untracked-files=all)"
if [ "$before" != "$after" ]; then
    echo "the run changed the working tree:"
    diff <(echo "$before") <(echo "$after") || true
    exit 1
fi
echo "unchanged"

printf '\nall checks passed\n'
