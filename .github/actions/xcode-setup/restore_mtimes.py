#!/usr/bin/env python3
"""Set every tracked file's modification time to the last commit that changed it.

A fresh checkout stamps every file with the time of the checkout. Xcode's build
system decides what to recompile from each input's mtime (plus size, inode and
device), so with checkout-time mtimes every source looks changed and a restored
DerivedData cache is recompiled from scratch. Pinning each file to its last
commit makes unchanged files look unchanged from one run to the next, so only
what a commit actually touched is rebuilt.

Needs the full history (`actions/checkout` with `fetch-depth: 0`). Files the
history does not reach keep their checkout mtime, which only costs a rebuild.
"""
import os
import subprocess

tracked = subprocess.run(
    ["git", "ls-files", "-z"], check=True, capture_output=True, text=True
).stdout.split("\0")
pending = {path for path in tracked if path}
total = len(pending)

# Newest commit first. `--first-parent -m` lists a merge's changes against main's
# side of it, so a file changed on a merged branch gets the merge's time.
log = subprocess.Popen(
    ["git", "-c", "core.quotePath=false", "log", "--first-parent", "-m",
     "--no-renames", "--name-only", "--format=%x00%ct", "HEAD"],
    stdout=subprocess.PIPE, text=True,
)
stamp = None
for line in log.stdout:
    line = line.rstrip("\n")
    if line.startswith("\0"):
        stamp = int(line[1:])
    elif line and stamp is not None and line in pending:
        os.utime(line, (stamp, stamp))
        pending.discard(line)
        if not pending:
            break
log.kill()
log.wait()

print(f"Restored commit mtimes on {total - len(pending)} of {total} tracked files.")
