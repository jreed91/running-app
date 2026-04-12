#!/bin/sh
set -e

echo "--- Installing XcodeGen ---"
brew install xcodegen

echo "--- Generating Xcode project from project.yml ---"
xcodegen generate

echo "--- Project generation complete ---"
