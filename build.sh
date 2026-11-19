#!/usr/bin/env bash
# Builds eloqc with the pinned Odin. Extra args go to odin (e.g. -o:speed).
set -euo pipefail
cd "$(dirname "$0")"

odin=vendor/odin/odin
version=$(cat odin-version)
if [[ ! -x $odin ]] || [[ $($odin version) != *"$version"* ]]; then
	echo "Odin $version missing from vendor/odin, run ./download-deps.sh" >&2
	exit 1
fi

$odin build source -out:eloqc "$@"
