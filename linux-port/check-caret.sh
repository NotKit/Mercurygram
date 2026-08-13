#!/bin/bash
# Checks that a text field draws the app's caret, not the framework's.
#
# EditTextBoldCursor styles its cursor (Telegram blue, 1.5 dp wide) and only
# draws it once the framework has drawn the marker drawable it returns from
# getTextCursorDrawable() -- API 29's contract. atlas had no such drawable and
# drew a black hairline of its own instead, so every field on the port showed a
# grey sliver (BRINGUP_NOTES.md).
#
# Boots the app, clicks the chat list's search field and types into it, then
# reads the pixels beside the text: the caret must be the app's colour and its
# width, not a hairline. Nothing is sent anywhere -- the search field is local,
# but it only exists once there is a session, so out/data has to hold one
# (transplant-session.sh).
#
# Usage: linux-port/check-caret.sh [--seconds N]
#   --seconds  upper bound on the run; it ends as soon as the shot is taken.
#              Default 240
#
# Writes out/run.log and out/screenshots/caret-*.png.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"
source "$PORT_DIR/launcher/display.sh"

seconds=240
while [ $# -gt 0 ]; do
	case "$1" in
	--seconds) seconds="$2"; shift 2 ;;
	*) echo "unknown option: $1" >&2; exit 1 ;;
	esac
done

# whatever $PORT_LAUNCHER selects, because the run below goes through run.sh
launcher="$PORT_LAUNCHER_BIN"
log="$PORT_OUT/run.log"
stop_file="$PORT_OUT/.caret-done"
shots="$PORT_OUT/screenshots"

command -v xdotool >/dev/null || { echo "xdotool is required to drive the UI" >&2; exit 1; }
[ -x "$launcher" ] || { echo "no launcher at $launcher (run build-atlas.sh)" >&2; exit 1; }

# The phone's density: the caret is dp-sized, and at density 1 it is a couple of
# pixels wide, which no screenshot can tell apart from the hairline it replaces.
export GRID_UNIT_PX="${GRID_UNIT_PX:-21}"

mkdir -p "$shots"
port_start_display

run_pid=""
cleanup() {
	rm -f "$stop_file"
	[ -n "$run_pid" ] && kill "$run_pid" 2>/dev/null || true
	# SIGKILL, not SIGTERM: the launcher ignores SIGTERM, and an instance left
	# running keeps talking to the account
	pkill -9 -f "^$launcher " 2>/dev/null || true
	[ -n "${PORT_XVFB_PID:-}" ] && kill "$PORT_XVFB_PID" 2>/dev/null || true
	return 0
}
trap cleanup EXIT

wait_for_log() {
	local pattern="$1" timeout="$2" waited=0
	while [ "$waited" -lt "$((timeout * 2))" ]; do
		# process substitution, not a pipe: grep -q exits on the first match and
		# the SIGPIPE that kills tail would fail the pipeline under pipefail
		if grep -qE -- "$pattern" <(cat "$log" 2>/dev/null); then
			return 0
		fi
		sleep 0.5
		waited=$((waited + 1))
	done
	return 1
}

echo "booting Mercurygram for up to ${seconds}s at density $(bc <<<"scale=3; $GRID_UNIT_PX/8")"
: >"$log"
"$PORT_DIR/run.sh" --seconds "$seconds" --stop-file "$stop_file" \
	>"$PORT_OUT/check-caret.log" 2>&1 &
run_pid=$!

wait_for_log 'boot: main activity started' 120 || {
	echo "the app never reached the main activity:" >&2
	tail -40 "$log" >&2
	exit 1
}
sleep 6

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

# Positions are per-mille of the ATLWindow, as in check-messages.sh. The chat
# list's search pill sits under the title bar.
click_at() {
	xdotool mousemove \
		"$((win_x + win_w * $1 / 1000))" \
		"$((win_y + win_h * $2 / 1000))" \
		sleep 0.2 click 1
}

port_screenshot "$shots/caret-before.png"
click_at 500 340
sleep 3
xdotool type --delay 120 "mg"
sleep 3
port_screenshot "$shots/caret-typed.png"
: >"$stop_file"

# --- verification -----------------------------------------------------------

[ -s "$shots/caret-typed.png" ] || { echo "no screenshot was taken" >&2; exit 1; }

python3 - "$shots/caret-typed.png" <<'PY'
import sys
from PIL import Image

# key_groupcreate_cursor, what EditTextBoldCursor asks for in a search field
WANT = (0x52, 0xa3, 0xdb)


def near(px, want, tol=40):
    return all(abs(a - b) <= tol for a, b in zip(px, want))


im = Image.open(sys.argv[1]).convert('RGB')
w, h = im.size
# only the opened search field's own row: the tab strip below it ("Chats") is
# the same blue, and so is the title above it
top, bottom = h * 4 // 100, h * 21 // 100
columns = {}
for x in range(w):
    n = sum(1 for y in range(top, bottom) if near(im.getpixel((x, y)), WANT))
    if n:
        columns[x] = n

if not columns:
    print("caret check: no cursor-coloured pixels in the search field")
    sys.exit(1)

runs, run = [], [min(columns)]
for x in sorted(columns)[1:]:
    if x == run[-1] + 1:
        run.append(x)
    else:
        runs.append(run)
        run = [x]
runs.append(run)
# the caret is a solid vertical bar: the tallest run of adjacent columns
caret = max(runs, key=lambda r: sum(columns[x] for x in r))
tall = max(columns[x] for x in caret)
print(f"caret: {len(caret)} px wide, {tall} px tall, at x={caret[0]}")
if len(caret) < 2 or tall < 20:
    print("caret check: that is a hairline, not the app's cursor")
    sys.exit(1)
print("caret check: passed")
PY

echo "screenshots in $shots/caret-*.png"
