#!/bin/bash
# Pushes to main already ship patch releases automatically (see .github/workflows/release.yml).
# Use this for a bigger bump: it tags the current commit and GitHub Actions builds and publishes it.
# Usage: ./release.sh 0.2.0
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?Usage: ./release.sh <version>}"
git tag "v$VERSION"
git push origin "v$VERSION"
echo "Tagged v$VERSION; follow the build with: gh run watch"
