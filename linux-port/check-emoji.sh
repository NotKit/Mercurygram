#!/bin/bash
# Checks that the emoji panel opens, renders the bundled sprite sheets,
# and a tapped emoji goes into the input field and out in a message.
#
# Boots the transplanted session with run.sh and drives the real UI with
# xdotool: overflow menu -> Saved Messages -> type a marker -> emoji button ->
# tap an emoji -> send. As in check-messages.sh, Saved Messages is the only
# chat this may write to and nothing is typed until the log says that is the
# chat that opened.
#
# What it requires afterwards:
#   the emoji button made the app open glyphs from assets/emoji/ (atlas logs
#     every AssetManager_openAsset), i.e. the panel really drew sprite sheets
#   the panel area of the screenshot is colourful, not a blank sheet
#   the tap changed the input field, and the message that went out to
#     inputPeerSelf carries the marker followed by a non-ASCII character --
#     read back out of the app's own cache4.db, not off a screenshot
#   the server acknowledged it with updateMessageID and the chat redrew
#
# Usage: linux-port/check-emoji.sh [--seconds N] [--from DIR] [--emoji-at X,Y]
#   --seconds    upper bound on the run; it ends as soon as the checks are
#                done. Default 900
#   --from       source data dir for the transplant
#   --emoji-at   where to tap in the panel, per-mille of the window.
#                Default 78,731 -- the first glyph of the first row
#
# Writes out/run.log and out/screenshots/emoji-*.png.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"
source "$PORT_DIR/launcher/display.sh"

seconds=900
from_args=()
emoji_at="78,731"

while [ $# -gt 0 ]; do
	case "$1" in
	--seconds) seconds="$2"; shift 2 ;;
	--from) from_args=(--from "$2"); shift 2 ;;
	--emoji-at) emoji_at="$2"; shift 2 ;;
	*) echo "unknown option: $1" >&2; exit 1 ;;
	esac
done

emoji_x="${emoji_at%,*}"
emoji_y="${emoji_at#*,}"

launcher="$ATLAS_OUT/android-translation-layer-hotspot"
log="$PORT_OUT/run.log"
stop_file="$PORT_OUT/.emoji-done"
shots="$PORT_OUT/screenshots"
data_dir="${ANDROID_APP_DATA_DIR:-$PORT_OUT/data}"
marker="mg-port-emoji-$(date +%s)"

command -v xdotool >/dev/null || { echo "xdotool is required to drive the UI" >&2; exit 1; }
command -v convert >/dev/null || { echo "ImageMagick is required" >&2; exit 1; }
[ -x "$launcher" ] || { echo "no launcher at $launcher (run build-atlas.sh)" >&2; exit 1; }

"$PORT_DIR/transplant-session.sh" "${from_args[@]}"

mkdir -p "$shots"
port_start_display

run_pid=""
cleanup() {
	rm -f "$stop_file"
	[ -n "$run_pid" ] && kill "$run_pid" 2>/dev/null || true
	# SIGKILL: the launcher ignores SIGTERM and a survivor keeps using the
	# account and holds the binary busy for the next build
	pkill -9 -f "^$launcher " 2>/dev/null || true
	[ -n "${PORT_XVFB_PID:-}" ] && kill "$PORT_XVFB_PID" 2>/dev/null || true
	return 0
}
trap cleanup EXIT

mark() { wc -l <"$log" 2>/dev/null || echo 0; }

wait_for_log() {
	local pattern="$1" timeout="$2" from="${3:-1}" waited=0
	while [ "$waited" -lt "$((timeout * 2))" ]; do
		# process substitution, not a pipe: grep -q exits on the first match and
		# the SIGPIPE that kills tail would fail the pipeline under pipefail
		if grep -qE -- "$pattern" <(tail -n "+$from" "$log" 2>/dev/null); then
			return 0
		fi
		sleep 0.5
		waited=$((waited + 1))
	done
	return 1
}

# Positions are per-mille of the ATLWindow, as in check-messages.sh.
click_at() {
	xdotool mousemove \
		"$((win_x + win_w * $1 / 1000))" \
		"$((win_y + win_h * $2 / 1000))" \
		sleep 0.2 click 1
}

# Unique colours in a per-mille rectangle of a screenshot: a drawn emoji grid
# has hundreds, an empty sheet a handful.
colours_in() {
	local png="$1" x="$2" y="$3" w="$4" h="$5"
	convert "$png" -crop \
		"$((win_w * w / 1000))x$((win_h * h / 1000))+$((win_w * x / 1000))+$((win_h * y / 1000))" \
		+repage -format %k info:
}

echo "booting Mercurygram for up to ${seconds}s with the transplanted session"
: >"$log"
"$PORT_DIR/run.sh" --seconds "$seconds" --stop-file "$stop_file" \
	>"$PORT_OUT/check-emoji.log" 2>&1 &
run_pid=$!

wait_for_log '^boot: main activity started' 90 || {
	echo "the app never reached the main activity:" >&2
	tail -40 "$log" >&2
	exit 1
}

# The account's own user id, which is also the id of the Saved Messages dialog.
self_id=""
for _ in $(seq 120); do
	self_id=$(grep -oE 'getSharedPreferences\(ringtones_pref_[0-9]+\)' "$log" 2>/dev/null |
		grep -oE '[0-9]+' | grep -vx 0 | head -1 || true)
	[ -n "$self_id" ] && break
	sleep 0.5
done
[ -n "$self_id" ] || {
	echo "could not tell which account is logged in; refusing to send anything" >&2
	exit 1
}
echo "logged in as $self_id (Saved Messages dialog $self_id)"

wait_for_log 'loaded folderId 0 loadType 1 count [0-9]+' 60 || {
	echo "no dialogs were loaded from the cache within 60s" >&2
	tail -40 "$log" >&2
	exit 1
}
if wait_for_log 'isUpdating = false' 420; then
	echo "updates caught up"
else
	echo "warning: still updating after 420s, driving the UI anyway" >&2
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

# --- open Saved Messages -----------------------------------------------------
# Same two guards as check-messages.sh: the overflow menu has to visibly open,
# and the chat that opens has to be dialog $self_id before anything is typed.

opened=0
for attempt in $(seq 6); do
	port_screenshot "$shots/emoji-chatlist.png"
	click_at 970 43
	sleep 2
	port_screenshot "$shots/emoji-menu.png"
	if cmp -s "$shots/emoji-chatlist.png" "$shots/emoji-menu.png"; then
		echo "the overflow menu did not open (attempt $attempt)" >&2
		sleep 5
		continue
	fi
	from=$(mark)
	click_at 906 252
	if wait_for_log "MessageLoaderLogger dialogId=$self_id " 30 "$from"; then
		opened=1
		echo "Saved Messages opened on attempt $attempt"
		break
	fi
	echo "that did not open Saved Messages (attempt $attempt), going back" >&2
	click_at 30 43
	sleep 3
done
[ "$opened" = 1 ] || {
	echo "could not open Saved Messages; nothing was typed or sent" >&2
	exit 1
}
sleep 4
port_screenshot "$shots/emoji-open.png"

# --- type the marker ---------------------------------------------------------
# The emoji is appended to it, so the message is greppable in cache4.db and the
# character after the marker is the proof the tap inserted a glyph.

echo "typing '$marker'"
click_at 417 935
sleep 1
xdotool type --delay 60 "$marker"
sleep 2
port_screenshot "$shots/emoji-marker.png"

# --- open the emoji panel ----------------------------------------------------

echo "opening the emoji panel"
panel_from=$(mark)
click_at 33 942
sleep 6
port_screenshot "$shots/emoji-panel.png"

# Every glyph the panel draws is one assets/emoji/<page>_<index>.png read
# through atlas's AssetManager; nothing else in the app opens those.
glyphs=$(grep -oE 'AssetManager_openAsset\([^,]+, assets/emoji/[0-9]+_[0-9]+\.png' \
	<(tail -n "+$panel_from" "$log") | sort -u | wc -l || true)
echo "the panel loaded $glyphs distinct emoji glyphs from assets/emoji/"
[ "$glyphs" -ge 20 ] || {
	echo "the emoji panel did not load sprite sheets from assets/emoji/" >&2
	tail -40 "$log" >&2
	exit 1
}

cmp -s "$shots/emoji-marker.png" "$shots/emoji-panel.png" && {
	echo "the screen did not change when the emoji button was tapped" >&2
	exit 1; }

# The panel is as tall as a phone keyboard, which on this window means it
# covers everything below the input row; the grid is the part below the tabs.
panel_colours=$(colours_in "$shots/emoji-panel.png" 0 620 1000 380)
echo "the grid area has $panel_colours distinct colours"
[ "$panel_colours" -ge 200 ] || {
	echo "the emoji panel drew but its grid is blank" >&2
	exit 1; }

# --- tap an emoji ------------------------------------------------------------

echo "tapping the emoji at ${emoji_x},${emoji_y}"
click_at "$emoji_x" "$emoji_y"
sleep 2
port_screenshot "$shots/emoji-inserted.png"

# --- close the panel ---------------------------------------------------------
# With the panel open the chat is pushed off the top of this window, so put the
# normal layout back before looking at the input field or sending. The action
# bar strip is the tell: it is only on screen when the panel is closed.
# The emoji button is where the input row is now, at the top of the window.

action_bar=$(colours_in "$shots/emoji-marker.png" 0 0 1000 60)
closed=0
for attempt in $(seq 3); do
	click_at 33 19
	sleep 2
	port_screenshot "$shots/emoji-closed.png"
	if [ "$(colours_in "$shots/emoji-closed.png" 0 0 1000 60)" = "$action_bar" ]; then
		closed=1
		break
	fi
	echo "the panel did not close (attempt $attempt)" >&2
done

if [ "$closed" = 1 ]; then
	send_at=(970 941)
	# Just the input field, so a repaint elsewhere cannot pass for an insertion.
	before=$(colours_in "$shots/emoji-marker.png" 40 910 700 80)
	after=$(colours_in "$shots/emoji-closed.png" 40 910 700 80)
	[ "$before" != "$after" ] || {
		echo "the input field did not change when the emoji was tapped" >&2
		exit 1; }
else
	# Send from the panel layout instead; the cache4.db check below is what
	# proves the emoji reached the message either way.
	echo "warning: sending with the panel still open" >&2
	send_at=(969 24)
fi

# --- send --------------------------------------------------------------------

echo "sending"
send_from=$(mark)
click_at "${send_at[@]}"

# inputPeerSelf serializes as all-zero ids: the proof it went to Saved Messages.
wait_for_log 'send message user_id = 0 chat_id = 0 channel_id = 0' 30 "$send_from" || {
	echo "no messages.sendMessage to inputPeerSelf after the click" >&2
	tail -40 "$log" >&2
	exit 1
}
# The ack. The port runs with the TL dumper off, so the response JSON
# is gone and the app applying the update is what proves the round trip.
wait_for_log 'process update TL_updateMessageID' 60 "$send_from" || {
	echo "the server never acknowledged the message" >&2
	tail -60 "$log" >&2
	exit 1
}
sleep 4
port_screenshot "$shots/emoji-sent.png"

# Everything driven is done.
touch "$stop_file"
echo "waiting for the run to finish"
status=0
wait "$run_pid" || status=$?
run_pid=""
[ "$status" = 0 ] || {
	echo "run.sh exited $status:" >&2
	cat "$PORT_OUT/check-emoji.log" >&2
	exit 1
}

# --- verification ------------------------------------------------------------

log_text=$(cat "$log")

if grep -q 'UnsatisfiedLinkError' <<<"$log_text"; then
	echo "an UnsatisfiedLinkError appeared:" >&2
	grep -B 2 -A 8 'UnsatisfiedLinkError' <<<"$log_text" >&2
	exit 1
fi

# What actually got sent, read out of the app's own message cache: the marker
# has to be followed by a non-ASCII character, which is the emoji the tap
# inserted. A screenshot could not tell an emoji from a placeholder box.
# The row is usually still in the write-ahead log, so both files are searched.
sent_text=$(python3 - "$data_dir/app.apk_/files/cache4.db" "$marker" <<-'PY'
	import re, sys
	db, marker = sys.argv[1], sys.argv[2]
	blob = b""
	for path in (db, db + "-wal"):
	    try:
	        with open(path, "rb") as f:
	            blob += f.read()
	    except FileNotFoundError:
	        pass
	found, best = False, ""
	for m in re.finditer(re.escape(marker.encode()), blob):
	    found = True
	    # The emoji is the last thing typed, so the message ends where the
	    # non-ASCII run after the marker does; what follows in the blob is the
	    # message's other fields.
	    tail = blob[m.end():m.end() + 32].decode("utf-8", "ignore")
	    glyph = ""
	    for c in tail:
	        if ord(c) < 0x80:
	            break
	        glyph += c
	    if len(glyph) > len(best):
	        best = glyph
	print(marker + best if found else "")
PY
)
[ -n "$sent_text" ] || {
	echo "the message with the marker is not in cache4.db" >&2; exit 1; }
echo "the message in cache4.db reads: $sent_text"
python3 -c 'import sys; t = sys.argv[1]; sys.exit(0 if any(ord(c) > 0x2000 for c in t) else 1)' \
	"$sent_text" || {
	echo "the sent message carries no emoji: the tap inserted nothing" >&2
	exit 1; }

# The sent bubble has to have drawn, glyph included.
cmp -s "$shots/emoji-closed.png" "$shots/emoji-sent.png" && {
	echo "the sent message never appeared in the chat" >&2; exit 1; }

all_glyphs=$(grep -oE 'AssetManager_openAsset\([^,]+, assets/emoji/[0-9]+_[0-9]+\.png' \
	"$log" | sort -u | wc -l || true)

echo
echo "emoji check passed:"
echo "  the panel opened and drew $glyphs glyphs from assets/emoji/ ($panel_colours colours)"
echo "  a tapped emoji went into the input field and out as '$sent_text'"
echo "  $all_glyphs distinct glyphs were read from the assets in all"
echo "  screenshots in $shots/emoji-*.png"
exit 0
