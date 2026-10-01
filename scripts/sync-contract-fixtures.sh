#!/usr/bin/env bash
# Copies the booking contract's fixtures into the test bundle and records the contract commit they came from.
#
# Usage: scripts/sync-contract-fixtures.sh [path-to-booking-contract] [commit]
#   path defaults to ../booking-contract next to this repository
#   commit defaults to 805815c, the contract version this package is pinned to
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
contract="${1:-$repo_root/../booking-contract}"
commit="${2:-805815c}"
target="$repo_root/Tests/TRPBookingKitTests/Fixtures/Contract"

if [ ! -d "$contract/.git" ]; then
    echo "booking-contract checkout not found at $contract" >&2
    exit 1
fi

if ! git -C "$contract" cat-file -e "$commit^{commit}" 2>/dev/null; then
    echo "commit $commit not found in $contract" >&2
    exit 1
fi

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

git -C "$contract" archive "$commit" fixtures | tar -x -C "$staging"

rm -rf "$target"
mkdir -p "$target"
cp -R "$staging/fixtures/." "$target/"
git -C "$contract" rev-parse --short=7 "$commit" > "$target/PINNED"

count="$(find "$target" -name '*.json' | wc -l | tr -d ' ')"
echo "Copied $count fixture files from $contract at $(cat "$target/PINNED") into $target"
