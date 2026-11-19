#!/usr/bin/env bash
# Fetches the pinned Odin compiler into vendor/odin.
set -euo pipefail
cd "$(dirname "$0")"

version=$(cat odin-version)
case "$(uname -s)-$(uname -m)" in
	Linux-x86_64)  platform=linux-amd64 ;;
	Linux-aarch64) platform=linux-arm64 ;;
	Darwin-arm64)  platform=macos-arm64 ;;
	*) echo "no Odin release for $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

rm -rf vendor/odin
mkdir -p vendor/odin
curl -fsSL "https://github.com/odin-lang/Odin/releases/download/$version/odin-$platform-$version.tar.gz" \
	| tar xz -C vendor/odin --strip-components=1
vendor/odin/odin version
