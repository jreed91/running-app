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
echo "--- Setting build number to $BUILD_NUMBER ---"
sed -i '' "s/CURRENT_PROJECT_VERSION: .*/CURRENT_PROJECT_VERSION: $BUILD_NUMBER/" project.yml

xcodegen generate

echo "--- Installing resolved Swift package pins ---"
mkdir -p Stride.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp ci_scripts/Package.resolved Stride.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved

echo "--- Project generation complete ---"
