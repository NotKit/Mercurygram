#!/bin/bash
# Cold start to first frame, and RSS at the chat list, for
# the HotSpot launcher and the image-backed one under one definition.
#
# The two runtimes are timed from the same argv run.sh builds, execed directly
# so nothing of run.sh's own is in the number, and alternated hotspot/image so
# drift on a busy host hits both columns. Cold means the page cache is dropped
# before every run (`sudo -n sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'`),
# which is why this is not part of any check-*.sh.
#
# Usage: linux-port/measure-startup.sh [--rounds N] [--seconds N] [--warm]
#                                      [--out DIR] [--data-dir DIR]
#   --rounds    hotspot+image pairs; default 4
#   --seconds   run length; also when RSS/PSS are read, so it must be past the
#               chat list on both backends. Default 75.
#   --warm      skip the cache drop (and the sudo it needs)
#   --out       where the logs, .xwd frames and the JSON go; default out/measure
#
# Needs a transplanted session in the data dir (transplant-session.sh), because
# "RSS at the chat list" means a populated list. Prints the summary table and
# leaves startup-results.json behind for a re-summary:
#   linux-port/measure-startup.py --summary out/measure/startup-results.json
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"
source "$PORT_DIR/launcher/display.sh"

rounds=4
seconds=75
warm=0
data_dir="${ANDROID_APP_DATA_DIR:-$PORT_OUT/data}"
out_dir="$PORT_OUT/measure"

while [ $# -gt 0 ]; do
	case "$1" in
	--rounds) rounds="$2"; shift 2 ;;
	--seconds) seconds="$2"; shift 2 ;;
	--warm) warm=1; shift ;;
	--out) out_dir="$2"; shift 2 ;;
	--data-dir) data_dir="$2"; shift 2 ;;
	*) echo "unknown option: $1" >&2; exit 1 ;;
	esac
done

command -v xwd >/dev/null || { echo "xwd is required to sample the screen" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }
for launcher in "$ATLAS_OUT/android-translation-layer-hotspot" \
	"$ATLAS_OUT/android-translation-layer-image"; do
	[ -x "$launcher" ] || { echo "no launcher at $launcher (run build-atlas.sh)" >&2; exit 1; }
done
[ -f "$PORT_IMAGE_LIB" ] || { echo "no image at $PORT_IMAGE_LIB (run build-image.sh)" >&2; exit 1; }
[ -d "$data_dir" ] || { echo "no data dir at $data_dir (run transplant-session.sh)" >&2; exit 1; }
if [ "$warm" = 0 ] && ! sudo -n true 2>/dev/null; then
	echo "dropping the page cache needs passwordless sudo; use --warm for warm runs" >&2
	exit 1
fi

mkdir -p "$out_dir"
port_start_display

export PORT_OUT ATLAS_OUT JAVA_HOME PORT_IMAGE_LIB
export PORT_MEASURE_OUT="$out_dir"
[ "$warm" = 0 ] || export NO_DROP=1

echo "measuring $rounds hotspot/image pairs of ${seconds}s each ($([ "$warm" = 1 ] && echo warm || echo cold))"
python3 "$PORT_DIR/measure-startup.py" "$DISPLAY" "$rounds" "$seconds" "$data_dir"

echo
python3 "$PORT_DIR/measure-startup.py" --summary "$out_dir/startup-results.json"
echo "logs, frames and JSON in $out_dir"
