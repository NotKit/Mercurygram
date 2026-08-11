#!/bin/bash
# Checks the chat list of a transplanted session.
#
# Transplants the ART/ATL desktop session if that has not been done yet, boots
# the app with run.sh (keeping the data dir), and requires in out/run.log that
# the dialogs came out of cache4.db with no SQLite error, then drags the list
# with xdotool and requires the window to actually change.
#
# Usage: linux-port/check-chatlist.sh [--seconds N] [--from DIR]
#   --seconds  upper bound on the run; it ends as soon as the checks are done,
#              so this only matters for a session with a long backlog. Default 900
#   --from     source data dir for the transplant (see transplant-session.sh)
#
# Writes out/run.log and out/screenshots/chatlist-*.png.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"
source "$PORT_DIR/launcher/display.sh"

seconds=900
from_args=()

while [ $# -gt 0 ]; do
	case "$1" in
	--seconds) seconds="$2"; shift 2 ;;
	--from) from_args=(--from "$2"); shift 2 ;;
	*) echo "unknown option: $1" >&2; exit 1 ;;
	esac
done

# whatever $PORT_LAUNCHER selects, because the run below goes through run.sh
launcher="$PORT_LAUNCHER_BIN"
log="$PORT_OUT/run.log"
stop_file="$PORT_OUT/.chatlist-done"
shots="$PORT_OUT/screenshots"

command -v xdotool >/dev/null || { echo "xdotool is required to drive the UI" >&2; exit 1; }
[ -x "$launcher" ] || { echo "no launcher at $launcher (run build-atlas.sh)" >&2; exit 1; }

"$PORT_DIR/transplant-session.sh" "${from_args[@]}"

mkdir -p "$shots"
port_start_display

run_pid=""
cleanup() {
	rm -f "$stop_file"
	[ -n "$run_pid" ] && kill "$run_pid" 2>/dev/null || true
	pkill -f "^$launcher " 2>/dev/null || true
	[ -n "${PORT_XVFB_PID:-}" ] && kill "$PORT_XVFB_PID" 2>/dev/null || true
	return 0
}
trap cleanup EXIT

wait_for_log() {
	local pattern="$1" timeout="$2" waited=0
	while [ "$waited" -lt "$((timeout * 2))" ]; do
		if grep -qE -- "$pattern" "$log" 2>/dev/null; then
			return 0
		fi
		sleep 0.5
		waited=$((waited + 1))
	done
	return 1
}

# A touch drag, positions in per-mille of the window: atlas has no scroll wheel
# callback, so a list is scrolled the way a finger would.
drag() {
	local fx="$1" fy0="$2" fy1="$3" steps=12
	local x=$((win_x + win_w * fx / 1000))
	local y0=$((win_y + win_h * fy0 / 1000)) y1=$((win_y + win_h * fy1 / 1000))
	xdotool mousemove "$x" "$y0" sleep 0.1 mousedown 1
	for i in $(seq "$steps"); do
		xdotool mousemove "$x" "$((y0 + (y1 - y0) * i / steps))" sleep 0.02
	done
	xdotool sleep 0.1 mouseup 1
	sleep 1
}

echo "booting Mercurygram for ${seconds}s with the transplanted session"
: >"$log"
"$PORT_DIR/run.sh" --seconds "$seconds" --stop-file "$stop_file" \
	>"$PORT_OUT/check-chatlist.log" 2>&1 &
run_pid=$!

wait_for_log '^boot: main activity started' 90 || {
	echo "the app never reached the main activity:" >&2
	tail -40 "$log" >&2
	exit 1
}

# --- dialogs out of the cache ------------------------------------------------
# MessagesController.processLoadedDialogs logs every load; loadType 1 is
# DIALOGS_LOAD_TYPE_CACHE, i.e. straight out of cache4.db.
wait_for_log 'loaded folderId 0 loadType 1 count [0-9]+' 60 || {
	echo "no dialogs were loaded from the cache within 60s" >&2
	tail -40 "$log" >&2
	exit 1
}

# A session that sat unused catches up on a week of updates first, and the main
# thread is busy enough during that to drop a drag. Wait for the app to say it
# is done ("Updating..." leaves the title) before touching anything.
if wait_for_log 'isUpdating = false' 420; then
	echo "updates caught up"
else
	echo "warning: still updating after 420s, trying to scroll anyway" >&2
fi
sleep 4

win=""
for _ in $(seq 20); do
	win=$(xdotool search --name '^Mercurygram' 2>/dev/null | head -1 || true)
	[ -n "$win" ] && break
	sleep 0.5
done
[ -n "$win" ] || { echo "no ATLWindow on $DISPLAY" >&2; exit 1; }
geometry=$(xdotool getwindowgeometry --shell "$win")
win_x=$(sed -n 's/^X=//p' <<<"$geometry")
win_y=$(sed -n 's/^Y=//p' <<<"$geometry")
win_w=$(sed -n 's/^WIDTH=//p' <<<"$geometry")
win_h=$(sed -n 's/^HEIGHT=//p' <<<"$geometry")
echo "ATLWindow $win at ${win_x},${win_y} ${win_w}x${win_h}"
xdotool windowfocus "$win" 2>/dev/null || true

# --- scrolling ---------------------------------------------------------------

# Retried: a session with a large backlog to catch up can be busy enough to
# ignore a gesture, and a UI that is not responding *at all* is the symptom that
# found the SvgHelper/SAX crash (see BRINGUP_NOTES.md).
echo "scrolling the chat list"
scrolled=0
for attempt in $(seq 12); do
	port_screenshot "$shots/chatlist-loaded.png"
	for _ in 1 2 3; do
		drag 500 800 200
	done
	port_screenshot "$shots/chatlist-scrolled.png"
	if ! cmp -s "$shots/chatlist-loaded.png" "$shots/chatlist-scrolled.png"; then
		scrolled=1
		echo "the list moved on attempt $attempt"
		break
	fi
	sleep 10
done
for _ in 1 2 3; do
	drag 500 200 800
done
port_screenshot "$shots/chatlist-top.png"

# Everything the check drives is done; run.sh stops on this instead of sitting
# out the timeout.
touch "$stop_file"
echo "waiting for the run to finish"
status=0
wait "$run_pid" || status=$?
run_pid=""
[ "$status" = 0 ] || {
	echo "run.sh exited $status:" >&2
	cat "$PORT_OUT/check-chatlist.log" >&2
	exit 1
}

# --- verification ------------------------------------------------------------

log_text=$(cat "$log")

count=$(grep -oE 'loaded folderId 0 loadType 1 count [0-9]+' <<<"$log_text" | head -1 | grep -oE '[0-9]+$')
[ "${count:-0}" -gt 0 ] || {
	echo "the cache load returned $count dialogs" >&2; exit 1; }

# The SQLite layer is the port's own build of jni/sqlite behind
# org/telegram/SQLite; a missing symbol or a database it cannot open shows here.
if grep -qE 'UnsatisfiedLinkError.*(SQLite|sqlite)' <<<"$log_text"; then
	echo "an SQLite JNI symbol is missing:" >&2
	grep -B 2 -A 8 'UnsatisfiedLinkError' <<<"$log_text" >&2
	exit 1
fi
sqlite_errors=$(grep -cE 'SQLiteException|sqlite3_(prepare|step|open).*(error|failed)' <<<"$log_text" || true)
[ "$sqlite_errors" = 0 ] || {
	echo "$sqlite_errors SQLite errors in $log:" >&2
	grep -E -A 8 'SQLiteException' <<<"$log_text" | head -40 >&2
	exit 1
}

# The list has to have actually moved: a frozen UI screenshots identically.
[ "$scrolled" = 1 ] || {
	echo "the window never changed while scrolling ($shots/chatlist-*.png)" >&2
	exit 1
}

echo
echo "chat list check passed:"
echo "  $count dialogs loaded from cache4.db, no SQLite errors"
echo "  the list scrolled, and run.sh saw no uncaught exception in the run"
echo "  screenshots in $shots/chatlist-*.png"
exit 0
