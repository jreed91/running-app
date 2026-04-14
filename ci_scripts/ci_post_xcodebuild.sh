#!/bin/sh
# ci_scripts/ci_post_xcodebuild.sh
#
# Runs after every xcodebuild action in Xcode Cloud.
# When this is an archive build (TestFlight distribution), it:
#   1. Generates "What to Test" notes from git commits since the last tag.
#   2. Saves the notes to testflight_notes.txt (always).
#   3. Uploads the notes to App Store Connect via the API (when credentials are set).
#
# Required environment variables for API upload (set as Xcode Cloud secrets):
#   ASC_KEY_ID        — API Key ID (from App Store Connect → Users & Access → Integrations)
#   ASC_ISSUER_ID     — Issuer ID (same page as the key)
#   ASC_PRIVATE_KEY   — Full contents of the downloaded .p8 private key file
#   ASC_APP_ID        — Numeric App ID (App Store Connect → App Information → Apple ID)
#
set -e

# Only generate TestFlight notes during archive builds.
if [ "$CI_XCODEBUILD_ACTION" != "archive" ]; then
    echo "Skipping TestFlight notes — not an archive build (action: ${CI_XCODEBUILD_ACTION:-unknown})."
    exit 0
fi

echo "--- Generating TestFlight 'What to Test' notes ---"

cd "$CI_PRIMARY_REPOSITORY_PATH"

# ── Determine the commit range ───────────────────────────────────────────────
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")

if [ -n "$LAST_TAG" ]; then
    RANGE="${LAST_TAG}..HEAD"
    echo "Commits since last tag: $LAST_TAG"
else
    # No tags yet — use the last 20 commits as a reasonable window.
    RANGE="HEAD~20..HEAD"
    echo "No tags found; using last 20 commits."
fi

# ── Build the notes body ─────────────────────────────────────────────────────
COMMITS=$(git log "$RANGE" --pretty=format:"• %s" --no-merges 2>/dev/null || echo "")

if [ -z "$COMMITS" ]; then
    COMMITS="• Build ${CI_BUILD_NUMBER:-local}"
fi

BRANCH="${CI_BRANCH:-unknown}"
BUILD="${CI_BUILD_NUMBER:-local}"

NOTES="Build ${BUILD} (${BRANCH})

What's changed:
${COMMITS}"

echo ""
echo "=== TestFlight Notes Preview ==="
echo "$NOTES"
echo "================================"
echo ""

# ── Save to file (always) ────────────────────────────────────────────────────
NOTES_FILE="$CI_PRIMARY_REPOSITORY_PATH/testflight_notes.txt"
printf '%s\n' "$NOTES" > "$NOTES_FILE"
echo "Notes written to: $NOTES_FILE"

# ── Upload via App Store Connect API (when credentials are configured) ───────
if [ -n "$ASC_KEY_ID" ] && [ -n "$ASC_ISSUER_ID" ] && [ -n "$ASC_PRIVATE_KEY" ] && [ -n "$ASC_APP_ID" ]; then
    echo "--- Uploading notes to TestFlight via App Store Connect API ---"
    python3 "$CI_PRIMARY_REPOSITORY_PATH/ci_scripts/upload_testflight_notes.py" \
        --key-id       "$ASC_KEY_ID"      \
        --issuer-id    "$ASC_ISSUER_ID"   \
        --private-key  "$ASC_PRIVATE_KEY" \
        --app-id       "$ASC_APP_ID"      \
        --build-number "$BUILD"           \
        --notes        "$NOTES"
else
    echo "--- Skipping API upload: App Store Connect credentials not configured ---"
    echo "To enable automatic upload, add these as Xcode Cloud environment variables:"
    echo "  ASC_KEY_ID      — API Key ID"
    echo "  ASC_ISSUER_ID   — Issuer ID"
    echo "  ASC_PRIVATE_KEY — .p8 private key contents"
    echo "  ASC_APP_ID      — Numeric App ID"
fi

echo "--- TestFlight notes step complete ---"
