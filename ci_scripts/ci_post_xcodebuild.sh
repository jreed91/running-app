#!/bin/sh
# ci_scripts/ci_post_xcodebuild.sh
#
# Runs after every xcodebuild action in Xcode Cloud.
# For archive builds, generates "What to Test" notes from recent git commits
# and writes them to TestFlight/WhatToTest.en-US.txt — the path Xcode Cloud
# reads automatically when distributing to TestFlight.
#
# Reference: https://developer.apple.com/documentation/xcode/including-notes-for-testers-with-a-beta-release-of-your-app
#
set -e

# Only run for archive builds (TestFlight distributions).
if [ "$CI_XCODEBUILD_ACTION" != "archive" ]; then
    echo "Skipping TestFlight notes — not an archive build (action: ${CI_XCODEBUILD_ACTION:-unknown})."
    exit 0
fi

echo "--- Generating TestFlight 'What to Test' notes ---"

cd "$CI_PRIMARY_REPOSITORY_PATH"

# ── Determine commit range ───────────────────────────────────────────────────
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")

if [ -n "$LAST_TAG" ]; then
    RANGE="${LAST_TAG}..HEAD"
    echo "Commits since tag: $LAST_TAG"
else
    RANGE="HEAD~20..HEAD"
    echo "No tags found; using last 20 commits."
fi

# ── Build the notes ──────────────────────────────────────────────────────────
COMMITS=$(git log "$RANGE" --pretty=format:"• %s" --no-merges 2>/dev/null || echo "")
[ -z "$COMMITS" ] && COMMITS="• Build ${CI_BUILD_NUMBER:-local}"

NOTES="Build ${CI_BUILD_NUMBER:-local} (${CI_BRANCH:-unknown})

Testing instructions:
Verify the changes from these commits:
${COMMITS}"

# ── Write to the file Xcode Cloud reads for TestFlight notes ─────────────────
mkdir -p TestFlight
printf '%s\n' "$NOTES" > TestFlight/WhatToTest.en-US.txt

echo ""
echo "=== TestFlight/WhatToTest.en-US.txt ==="
cat TestFlight/WhatToTest.en-US.txt
echo "========================================"
echo ""
echo "--- TestFlight notes step complete ---"
