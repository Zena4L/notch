#!/bin/sh
# Rebuilds Vendor/MediaRemoteAdapter from source (needs cmake: `brew install cmake`).
# Notch runs this framework through /usr/bin/perl to read Now Playing on macOS 15.4+.
set -eu
COMMIT=29718252613a5b0e210bdc64de0bd944ab379706
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Vendor/MediaRemoteAdapter"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git clone -q https://github.com/ungive/mediaremote-adapter.git "$WORK/src"
git -C "$WORK/src" checkout -q "$COMMIT"
cmake -S "$WORK/src" -B "$WORK/build" >/dev/null
cmake --build "$WORK/build" --target MediaRemoteAdapter >/dev/null

rm -rf "$OUT" && mkdir -p "$OUT"
cp -R "$WORK/build/MediaRemoteAdapter.framework" "$OUT/"
cp "$WORK/src/bin/mediaremote-adapter.pl" "$WORK/src/LICENSE" "$OUT/"
echo "$COMMIT" > "$OUT/COMMIT"
echo "Updated $OUT at $COMMIT"
