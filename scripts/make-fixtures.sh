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
	clip="$out/$name-${seconds}s.ts"
	head -c "$bytes" "$src" > "$clip"
	# ground truth for the Swift parser tests: per-PID packet/frame counts
	if command -v ffprobe >/dev/null; then
		ffprobe -v error -count_packets -count_frames -show_entries \
			stream=id,codec_name,codec_type,field_order,sample_rate,channels,profile,nb_read_packets,nb_read_frames \
			-of json "$clip" > "${clip%.ts}.expect.json" 2>/dev/null
	fi
	echo "$clip"
done
