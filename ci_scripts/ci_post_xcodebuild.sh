#!/bin/sh
# ci_scripts/ci_post_xcodebuild.sh
#
# Runs after every xcodebuild action in Xcode Cloud.
# For archive builds, generates "What to Test" notes from the commits that
# landed since the previous build and writes them to
# TestFlight/WhatToTest.en-US.txt — the path Xcode Cloud reads automatically
# when distributing to TestFlight.
#
# Reference: https://developer.apple.com/documentation/xcode/including-notes-for-testers-with-a-beta-release-of-your-app
#
# To see what a build would send to testers, run it against the checkout:
#   CI_XCODEBUILD_ACTION=archive sh ci_scripts/ci_post_xcodebuild.sh
#
set -e

# How many changes a tester is asked to read, and the ceiling App Store Connect
# puts on the "What to Test" field (4000 characters — the margin leaves room for
# the header and the "and N more" line).
MAX_ENTRIES=15
MAX_NOTES_CHARS=3800

# Tag marking a commit that has already shipped to TestFlight. See "Picking the
# range" below — nothing in this script creates one.
RELEASE_TAG_GLOB='testflight/*'

# Only run for archive builds (TestFlight distributions).
if [ "$CI_XCODEBUILD_ACTION" != "archive" ]; then
    echo "Skipping TestFlight notes — not an archive build (action: ${CI_XCODEBUILD_ACTION:-unknown})."
    exit 0
fi

echo "--- Generating TestFlight 'What to Test' notes ---"

# Outside Xcode Cloud CI_PRIMARY_REPOSITORY_PATH is unset; fall back to the
# checkout this script lives in so the notes can be previewed locally.
cd "${CI_PRIMARY_REPOSITORY_PATH:-$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)}"

# ── Picking the range ────────────────────────────────────────────────────────
# Xcode Cloud tells a build nothing about the build before it — there is no
# "previous build's commit" variable to diff against — so the range has to come
# out of the repository. Three sources, most precise first:
#
#   1. A `testflight/*` tag. Nothing here creates one (Xcode Cloud clones with
#      read-only credentials), but if a release process starts pushing them the
#      changelog becomes exactly "everything since the last build testers saw"
#      with no further edits to this script.
#   2. HEAD being a merge commit, which on main means the pull request that
#      triggered this build: its first parent is main before the merge, so
#      HEAD^1..HEAD is precisely the work that PR brought in. This is the case
#      that fires in practice.
#   3. Neither — a direct push, or a build off a topic branch. Fall back to the
#      most recent commits. Imprecise at the boundary, but a tester still gets a
#      list of what changed instead of a single subject line.
last_release_tag() {
    head_sha=$(git rev-parse HEAD 2>/dev/null) || return 0
    git tag --list "$RELEASE_TAG_GLOB" --sort=-creatordate 2>/dev/null | while IFS= read -r tag; do
        [ -n "$tag" ] || continue
        tag_sha=$(git rev-parse --verify --quiet "${tag}^{commit}") || continue
        [ "$tag_sha" = "$head_sha" ] && continue
        if git merge-base --is-ancestor "$tag_sha" HEAD 2>/dev/null; then
            echo "$tag"
            break
        fi
    done
}

RELEASE_TAG=$(last_release_tag)
if [ -n "$RELEASE_TAG" ]; then
    RANGE_ARGS="${RELEASE_TAG}..HEAD"
    RANGE_SOURCE="commits since ${RELEASE_TAG}"
elif git rev-parse --verify --quiet 'HEAD^2' >/dev/null 2>&1; then
    RANGE_ARGS="HEAD^1..HEAD"
    RANGE_SOURCE="commits merged by HEAD"
else
    RANGE_ARGS="-n $MAX_ENTRIES HEAD"
    RANGE_SOURCE="the last $MAX_ENTRIES commits"
fi

echo "Changelog range: $RANGE_SOURCE"

# ── Collect the subjects ─────────────────────────────────────────────────────
# --no-merges keeps the merge commits out: their subject is "Merge pull request
# #N from <branch>", which tells a tester nothing, while the commits underneath
# describe the actual change. The grep drops in-progress commits that are only
# meaningful to whoever wrote them, and awk removes duplicate subjects (a commit
# reachable through two merges, or the same fix applied twice).
filter_subjects() {
    sed 's/[[:space:]]*$//' \
        | grep -v -E '^[[:space:]]*$' \
        | grep -v -i -E '^(wip|fixup!|squash!|revert "?wip)([[:space:][:punct:]]|$)' \
        | awk '!seen[$0]++' \
        || true
}

SUBJECTS=$(git log --no-merges --pretty=format:'%s' $RANGE_ARGS 2>/dev/null || true)
SUBJECTS=$(printf '%s\n' "$SUBJECTS" | filter_subjects)

HEADER="Build ${CI_BUILD_NUMBER:-local} (${CI_BRANCH:-unknown})"

if [ -n "$SUBJECTS" ]; then
    CHANGES=$(printf '%s\n' "$SUBJECTS" | awk \
        -v max="$MAX_ENTRIES" \
        -v budget="$(( MAX_NOTES_CHARS - ${#HEADER} - 32 ))" '
        {
            line = "• " $0
            if (kept >= max || used + length(line) + 1 > budget) { skipped++; next }
            print line
            kept++
            used += length(line) + 1
        }
        END {
            if (skipped > 0)
                printf "• …and %d more change%s\n", skipped, (skipped == 1 ? "" : "s")
        }')
    NOTES="${HEADER}

What's new:
${CHANGES}"
else
    # No usable subjects: an empty range, or every commit in it filtered out.
    # Fall back to the tip commit — through the same filter, so a build whose
    # only commit was a WIP does not get that subject handed to testers anyway.
    LAST_COMMIT=$(git log -1 --pretty=format:'%s' 2>/dev/null | filter_subjects || true)
    [ -z "$LAST_COMMIT" ] && LAST_COMMIT="No changelog available for this build."
    NOTES="${HEADER}

${LAST_COMMIT}"
fi

# ── Write to the file Xcode Cloud reads for TestFlight notes ─────────────────
mkdir -p TestFlight
printf '%s\n' "$NOTES" > TestFlight/WhatToTest.en-US.txt

echo ""
echo "=== TestFlight/WhatToTest.en-US.txt ==="
cat TestFlight/WhatToTest.en-US.txt
echo "========================================"
echo ""
echo "--- TestFlight notes step complete ---"
