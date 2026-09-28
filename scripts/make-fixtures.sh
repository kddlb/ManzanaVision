#!/bin/sh
# Cuts short test clips out of longer full-mux captures for the Swift tests
# and mzvtool. Captures stay local (they're broadcast content); point
# MANZANA_FIXTURES at the output directory when running `swift test`.
#
#   scripts/make-fixtures.sh rf27-5min.ts rf32-5min.ts
set -eu
cd "$(dirname "$0")/.."
out=${MANZANA_FIXTURES:-fixtures}
mkdir -p "$out"
seconds=${SECONDS_PER_CLIP:-20}
for src in "$@"; do
	name=$(basename "$src" .ts)
	# full-mux rate is ~17-18 Mbit/s; cut on a 188-byte packet boundary
	bytes=$(( seconds * 2300000 / 188 * 188 ))
	head -c "$bytes" "$src" > "$out/$name-${seconds}s.ts"
	echo "$out/$name-${seconds}s.ts"
done
