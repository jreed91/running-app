#!/usr/bin/env python3
"""Download the app screenshots CI took, so the running app can be looked at.

    python3 scripts/fetch_app_screenshots.py                # this checkout's branch
    python3 scripts/fetch_app_screenshots.py --pr 541
    python3 scripts/fetch_app_screenshots.py --branch main
    python3 scripts/fetch_app_screenshots.py --run 46061511892 --out /tmp/shots

CI's `Test — iOS (screenshots)` job runs `UXCaptureTests`, which walks onboarding, every tab, the Plan
tools pages, a run summary, Achievements, Settings and the run screen, and uploads the
shots as the `app-screenshots` artifact. This finds the newest CI run for the PR, branch
or run id, downloads that artifact (or, for runs from before it existed, pulls the PNGs
out of `test-results-ios-capture`, or `test-results-ios` before CI was split), and writes:

    <out>/UXCaptureTests/NN-<screen>.png   full-size shots, in the order they were taken
    <out>/sheet-N.png                      contact sheets, eight shots each (needs Pillow)

Needs the `gh` CLI signed in. Standard library only, apart from Pillow for the sheets.
"""

from __future__ import annotations

import argparse
import io
import json
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

REPO = "jreed91/running-app"
HERE = Path(__file__).resolve().parent
# The result bundle holding UXCaptureTests: its own runner's since CI was split into
# three runners (2026-11-27), the one test job's before that.
RESULTS = ("test-results-ios-capture", "test-results-ios")


def gh(path: str, raw: bool = False):
    out = subprocess.run(["gh", "api", path], check=True, capture_output=True).stdout
    return out if raw else json.loads(out)


def current_branch() -> str:
    return subprocess.run(
        ["git", "rev-parse", "--abbrev-ref", "HEAD"], check=True, capture_output=True, text=True
    ).stdout.strip()


def find_run(args) -> dict:
    if args.run:
        return gh(f"repos/{REPO}/actions/runs/{args.run}")
    branch = args.branch
    if args.pr:
        branch = gh(f"repos/{REPO}/pulls/{args.pr}")["head"]["ref"]
    branch = branch or current_branch()
    runs = gh(f"repos/{REPO}/actions/workflows/ci.yml/runs?branch={branch}&per_page=20")["workflow_runs"]
    # Newest run that got as far as uploading something. A run cancelled by a later push
    # or still in progress has no artifacts yet, so skip to the one before it.
    for run in runs:
        names = {a["name"] for a in gh(f"repos/{REPO}/actions/runs/{run['id']}/artifacts")["artifacts"] if not a["expired"]}
        if names & {"app-screenshots", *RESULTS}:
            return run
    sys.exit(f"No CI run on {branch} has screenshots yet (checked {len(runs)} runs).")


def download(run: dict, out: Path) -> None:
    artifacts = {a["name"]: a for a in gh(f"repos/{REPO}/actions/runs/{run['id']}/artifacts")["artifacts"] if not a["expired"]}
    if "app-screenshots" in artifacts:
        blob = gh(f"repos/{REPO}/actions/artifacts/{artifacts['app-screenshots']['id']}/zip", raw=True)
        zipfile.ZipFile(io.BytesIO(blob)).extractall(out)
        return
    results = next((name for name in RESULTS if name in artifacts), None)
    if not results:
        sys.exit(f"Run {run['id']} has no screenshots artifact.")
    print(f"No app-screenshots artifact on this run; extracting from {results} (large download).")
    blob = gh(f"repos/{REPO}/actions/artifacts/{artifacts[results]['id']}/zip", raw=True)
    with tempfile.TemporaryDirectory() as tmp:
        zipfile.ZipFile(io.BytesIO(blob)).extractall(tmp)
        bundle = Path(tmp) / "ui.xcresult"
        subprocess.run([sys.executable, str(HERE / "export_screenshots.py"), str(bundle), str(out)], check=True)


def contact_sheets(out: Path, per_sheet: int = 8) -> list[Path]:
    try:
        from PIL import Image, ImageDraw
    except ImportError:
        print("Pillow not installed; skipping contact sheets.")
        return []
    shots = sorted(out.glob("UXCaptureTests/*.png")) or sorted(out.glob("*/*.png"))
    sheets = []
    width, height, label = 300, 652, 22
    for start in range(0, len(shots), per_sheet):
        chunk = shots[start:start + per_sheet]
        sheet = Image.new("RGB", (width * len(chunk), height + label), "white")
        draw = ImageDraw.Draw(sheet)
        for i, path in enumerate(chunk):
            image = Image.open(path).convert("RGB")
            image.thumbnail((width, height))
            sheet.paste(image, (width * i, label))
            draw.text((width * i + 4, 4), path.stem, fill="black")
        target = out / f"sheet-{start // per_sheet + 1}.png"
        sheet.save(target)
        sheets.append(target)
    return sheets


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--pr", type=int)
    source.add_argument("--branch")
    source.add_argument("--run", type=int)
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()

    run = find_run(args)
    out = args.out or Path(tempfile.gettempdir()) / f"app-screenshots-{run['id']}"
    out.mkdir(parents=True, exist_ok=True)
    print(f"Run {run['id']} on {run['head_branch']} @ {run['head_sha'][:7]} ({run['conclusion'] or run['status']})")
    download(run, out)
    shots = sorted(out.glob("*/*.png"))
    sheets = contact_sheets(out)
    print(f"{len(shots)} screenshot(s) in {out}")
    for sheet in sheets:
        print(f"  {sheet}")


if __name__ == "__main__":
    main()
