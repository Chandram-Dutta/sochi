#!/usr/bin/env bash
# Builds a release archive of sochi: a universal (arm64 + x86_64) binary stamped with the given version,
# packed as dist/sochi-macos-universal.tar.gz with a .sha256 next to it. No git changes; used by the release
# workflow (.github/workflows/release.yml) and runnable locally to try a release build.
#
#   scripts/build-release.sh 0.1.0
set -euo pipefail

version="${1:?usage: scripts/build-release.sh <version>}"
version="${version#v}"
asset="sochi-macos-universal.tar.gz"
cd "$(dirname "$0")/.."

# Stamp the version for this build only, restoring the file afterwards.
version_file="Sources/sochi/Version.swift"
original="$(cat "$version_file")"
trap 'printf "%s\n" "$original" > "$version_file"' EXIT
printf '/// Set by scripts/build-release.sh from the release tag; "dev" for builds from source.\nlet sochiVersion = "%s"\n' "$version" > "$version_file"

bin_dir="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path | tail -1)"
swift build -c release --arch arm64 --arch x86_64
bin="$bin_dir/sochi"
for arch in arm64 x86_64; do lipo "$bin" -verify_arch "$arch"; done
[ "$("$bin" --version)" = "$version" ] || { echo "Built binary reports the wrong version." >&2; exit 1; }

rm -rf dist && mkdir dist
cp "$bin" dist/sochi
strip -x dist/sochi
tar -czf "dist/$asset" -C dist sochi
(cd dist && shasum -a 256 "$asset" > "$asset.sha256")
echo "dist/$asset $(awk '{print $1}' "dist/$asset.sha256")"
