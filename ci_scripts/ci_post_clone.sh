#!/bin/sh
set -e

# Xcode Cloud agents are Apple Silicon; /bin/sh doesn't source profile so
# Homebrew isn't in PATH by default. Add both ARM and Intel locations.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# Xcode Cloud performs a shallow clone by default, which means git log and
# git describe --tags won't see full history or tags. Unshallow so the
# ci_post_xcodebuild.sh script can build accurate TestFlight release notes.
echo "--- Fetching full git history for release notes ---"
git -C "$CI_PRIMARY_REPOSITORY_PATH" fetch --unshallow --tags 2>/dev/null \
    || git -C "$CI_PRIMARY_REPOSITORY_PATH" fetch --tags 2>/dev/null \
    || echo "Warning: could not fetch full history; release notes may be incomplete."

echo "--- Installing XcodeGen ---"
HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 brew install xcodegen

echo "--- Generating Xcode project from project.yml ---"
cd "$CI_PRIMARY_REPOSITORY_PATH"

# CI_BUILD_NUMBER is provided by Xcode Cloud and increments with every build.
# Fall back to the git commit count when running outside Xcode Cloud.
BUILD_NUMBER="${CI_BUILD_NUMBER:-$(git rev-list --count HEAD)}"

# The build number is written to the xcconfig that project.yml's `configFiles`
# points at. This used to be an in-place `sed` against project.yml itself, which
# matched on that YAML file's exact key formatting and failed silently if it ever
# changed — producing a duplicate build number that TestFlight only rejects after
# a complete archive. Rewriting the whole xcconfig removes the pattern match, and
# the verification below turns any remaining failure into a hard error here.
VERSION_XCCONFIG="ci_scripts/Version.xcconfig"

MARKETING_VERSION="$(sed -n 's/^[[:space:]]*MARKETING_VERSION[[:space:]]*=[[:space:]]*//p' "$VERSION_XCCONFIG" | head -1 | tr -d '[:space:]')"
if [ -z "$MARKETING_VERSION" ]; then
    echo "Error: could not read MARKETING_VERSION from $VERSION_XCCONFIG" >&2
    exit 1
fi

echo "--- Setting version to $MARKETING_VERSION ($BUILD_NUMBER) ---"
cat > "$VERSION_XCCONFIG" <<EOF
// Generated during CI by ci_scripts/ci_post_clone.sh. The committed version of
// this file documents why it exists and holds the checked-in defaults.
MARKETING_VERSION = $MARKETING_VERSION
CURRENT_PROJECT_VERSION = $BUILD_NUMBER
#include? "Strava.xcconfig"
EOF

grep -q "^CURRENT_PROJECT_VERSION = ${BUILD_NUMBER}$" "$VERSION_XCCONFIG" || {
    echo "Error: failed to write build number $BUILD_NUMBER to $VERSION_XCCONFIG" >&2
    exit 1
}

# Strava upload credentials, from the workflow's secret environment variables. Without
# them the build simply has no Strava feature. Strava.xcconfig is gitignored, and the
# values are never echoed.
if [ -n "${STRAVA_CLIENT_ID:-}" ] && [ -n "${STRAVA_CLIENT_SECRET:-}" ]; then
    echo "--- Writing Strava client configuration ---"
    printf 'STRAVA_CLIENT_ID = %s\nSTRAVA_CLIENT_SECRET = %s\n' \
        "$STRAVA_CLIENT_ID" "$STRAVA_CLIENT_SECRET" > ci_scripts/Strava.xcconfig
else
    echo "--- No Strava credentials set; building without Strava upload ---"
fi

xcodegen generate

echo "--- Installing resolved Swift package pins ---"
mkdir -p Stride.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp ci_scripts/Package.resolved Stride.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved

echo "--- Project generation complete ---"
