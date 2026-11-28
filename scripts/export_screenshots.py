#!/usr/bin/env python3
"""Copy every PNG attachment out of an .xcresult bundle as a loose file.

    python3 scripts/export_screenshots.py TestResults/ui.xcresult AppScreenshots

Works on macOS and on Linux, with the standard library only: it reads the bundle's
`database.sqlite3` index (Xcode 16+) for each attachment's name and test, and copies the
payload from `Data/`. `xcresulttool` is not needed, so an agent on a Linux box can run it
on a downloaded `test-results-ios` artifact as well as CI can on the runner.

Output: `<out>/<TestClass>/<attachment name>.png`, e.g.
`UXCaptureTests/13-tab-plan-top.png`, and an `index.txt` listing them.
"""

from __future__ import annotations

import re
import sqlite3
import sys
import zlib
from pathlib import Path

PNG_MAGIC = b"\x89PNG\r\n\x1a\n"
ZSTD_MAGIC = b"\x28\xb5\x2f\xfd"


def safe(name: str) -> str:
    name = re.sub(r"[^A-Za-z0-9._-]+", "-", name).strip("-")
    return name or "unnamed"


def payload(data_dir: Path, ref: str) -> bytes | None:
    path = data_dir / f"data.{ref}"
    if not path.exists():
        return None
    raw = path.read_bytes()
    if raw.startswith(PNG_MAGIC):
        return raw
    if raw.startswith(ZSTD_MAGIC):
        try:
            import zstandard  # optional; screenshots have been stored raw so far
        except ImportError:
            print(f"skip {path.name}: zstd-compressed and `zstandard` is not installed", file=sys.stderr)
            return None
        return zstandard.ZstdDecompressor().decompress(raw, max_output_size=64 << 20)
    try:
        return zlib.decompress(raw)
    except zlib.error:
        return None


def export_unnamed(bundle: Path, out: Path) -> int:
    folder = out / "unnamed"
    folder.mkdir(parents=True, exist_ok=True)
    written = []
    for path in sorted((bundle / "Data").glob("data.*")):
        with path.open("rb") as handle:
            if handle.read(8) != PNG_MAGIC:
                continue
        target = folder / f"{len(written) + 1:03d}.png"
        target.write_bytes(path.read_bytes())
        written.append(target)
    (out / "index.txt").write_text("".join(f"{p.relative_to(out)}\n" for p in written))
    print(f"Exported {len(written)} unnamed screenshot(s) to {out}")
    return 0


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    bundle, out = Path(sys.argv[1]), Path(sys.argv[2])
    db = bundle / "database.sqlite3"
    if not db.exists():
        # The index only exists once xcresulttool has read the bundle (CI's export step
        # does that first). Without it, the PNGs can still be found by their magic bytes,
        # just not named or ordered.
        print(f"{db} not found; saving PNGs by content, without names", file=sys.stderr)
        return export_unnamed(bundle, out)

    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    # Attachment → activity → test case run → test case → suite. Any link can be
    # missing (an attachment added outside an activity), so every join is LEFT.
    rows = con.execute(
        """
        SELECT a.name, a.xcResultKitPayloadRefId, a.timestamp, s.name, tc.name
        FROM Attachments a
        LEFT JOIN Activities ac ON a.activity_fk = ac.rowid
        LEFT JOIN TestCaseRuns r ON ac.testCaseRun_fk = r.rowid
        LEFT JOIN TestCases tc ON r.testCase_fk = tc.rowid
        LEFT JOIN TestSuites s ON tc.testSuite_fk = s.rowid
        WHERE a.uniformTypeIdentifier = 'public.png'
        ORDER BY a.timestamp
        """
    ).fetchall()

    written = []
    for name, ref, _, suite, test in rows:
        data = payload(bundle / "Data", ref)
        if not data:
            continue
        folder = out / safe(suite or "Other")
        folder.mkdir(parents=True, exist_ok=True)
        target = folder / f"{safe(name or ref[:12])}.png"
        n = 2
        while target in written:
            target = folder / f"{safe(name or ref[:12])}-{n}.png"
            n += 1
        target.write_bytes(data)
        written.append(target)

    out.mkdir(parents=True, exist_ok=True)
    (out / "index.txt").write_text("".join(f"{p.relative_to(out)}\n" for p in written))
    print(f"Exported {len(written)} screenshot(s) to {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
