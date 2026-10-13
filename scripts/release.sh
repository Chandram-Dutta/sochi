#!/usr/bin/env bash
# Builds a release of sochi: universal binary, archive + checksum, version bump, Homebrew formula, tag.
#
#   scripts/release.sh 0.1.0            build and tag locally; prints the publish commands
#   scripts/release.sh 0.1.0 --publish  also pushes main and the tag, and creates the GitHub release
set -euo pipefail

version="${1:?usage: scripts/release.sh <version> [--publish]}"
publish="${2:-}"
repo="Chandram-Dutta/sochi"
asset="sochi-macos-universal.tar.gz"
cd "$(dirname "$0")/.."

git diff --quiet && git diff --cached --quiet || { echo "Commit or stash your changes first." >&2; exit 1; }
git rev-parse "v$version" >/dev/null 2>&1 && { echo "Tag v$version already exists." >&2; exit 1; }

echo "== tests"
swift test

echo "== version $version"
printf '/// Set by scripts/release.sh.\nlet sochiVersion = "%s"\n' "$version" > Sources/sochi/Version.swift

echo "== universal release build"
swift build -c release --arch arm64 --arch x86_64
bin="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/sochi"
lipo "$bin" -verify_arch arm64 x86_64
[ "$("$bin" --version)" = "$version" ] || { echo "Built binary reports the wrong version." >&2; exit 1; }

rm -rf dist && mkdir dist
cp "$bin" dist/sochi
strip -x dist/sochi
tar -czf "dist/$asset" -C dist sochi
(cd dist && shasum -a 256 "$asset" > "$asset.sha256")
sha="$(awk '{print $1}' "dist/$asset.sha256")"

echo "== Homebrew formula"
sed -i '' -E \
    -e "s|releases/download/v[^/]+/|releases/download/v$version/|" \
    -e "s|^  sha256 \".*\"|  sha256 \"$sha\"|" \
    -e "s|^  version \".*\"|  version \"$version\"|" \
    Formula/sochi.rb

git add Sources/sochi/Version.swift Formula/sochi.rb
git commit -m "Release v$version"
git tag -a "v$version" -m "sochi $version"

if [ "$publish" = "--publish" ]; then
    git push origin main "v$version"
    gh release create "v$version" "dist/$asset" "dist/$asset.sha256" -R "$repo" --title "sochi $version" --generate-notes
    echo "Published: https://github.com/$repo/releases/tag/v$version"
else
    echo
    echo "Built dist/$asset ($sha). To publish:"
    echo "  git push origin main v$version"
    echo "  gh release create v$version dist/$asset dist/$asset.sha256 -R $repo --title \"sochi $version\" --generate-notes"
fi
