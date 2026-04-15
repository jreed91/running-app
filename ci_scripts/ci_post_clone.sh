#!/bin/sh
set -e

echo "--- Installing XcodeGen ---"
brew install xcodegen

echo "--- Generating Xcode project from project.yml ---"
cd "$CI_PRIMARY_REPOSITORY_PATH"

# CI_BUILD_NUMBER is provided by Xcode Cloud and increments with every build.
# Fall back to the git commit count when running outside Xcode Cloud.
BUILD_NUMBER="${CI_BUILD_NUMBER:-$(git rev-list --count HEAD)}"
echo "--- Setting build number to $BUILD_NUMBER ---"
sed -i '' "s/CURRENT_PROJECT_VERSION: .*/CURRENT_PROJECT_VERSION: $BUILD_NUMBER/" project.yml

xcodegen generate

echo "--- Project generation complete ---"
