#!/bin/bash
# Checks that a chat opens, a text message sends, and one is received.
#
# Boots the transplanted session with run.sh and drives the real UI with
# xdotool: overflow menu -> Saved Messages -> type -> send. Saved Messages is
# the only chat this may write to, so the script refuses to type until the log
# says the dialog it opened is the account's own (see $self_id below).
#
# What it requires afterwards, in out/run.log:
#   the chat loaded its messages from cache and drew without an exception
#   messages.sendMessage went out to inputPeerSelf (user_id/chat_id/channel_id 0)
#   the server answered with updateMessageID, i.e. the local message got a real
#     id -- the single->double check the story asks for
#   an incoming message from the update loop was processed while the app kept
#     running, and the chat list redrew because of it
#
# The incoming half rides on the account's own live traffic: a self-contained
# one would need a second client on the same account. See BRINGUP_NOTES.md.
#
# Usage: linux-port/check-messages.sh [--seconds N] [--incoming-seconds N]
#                                     [--from DIR]
#   --seconds           upper bound on the run; it ends as soon as the checks
#                       are done. Default 900
#   --incoming-seconds  how long to wait for an incoming message. Default 300
#   --from              source data dir for the transplant
#
# Writes out/run.log and out/screenshots/messages-*.png.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"
source "$PORT_DIR/launcher/display.sh"

seconds=900
incoming_seconds=300
from_args=()

while [ $# -gt 0 ]; do
	case "$1" in
	--seconds) seconds="$2"; shift 2 ;;
	--incoming-seconds) incoming_seconds="$2"; shift 2 ;;
	--from) from_args=(--from "$2"); shift 2 ;;
	*) echo "unknown option: $1" >&2; exit 1 ;;
	esac
done

launcher="$ATLAS_OUT/android-translation-layer-hotspot"
log="$PORT_OUT/run.log"
stop_file="$PORT_OUT/.messages-done"
shots="$PORT_OUT/screenshots"
text="mg-port-msg-$(date +%s)"

command -v xdotool >/dev/null || { echo "xdotool is required to drive the UI" >&2; exit 1; }
[ -x "$launcher" ] || { echo "no launcher at $launcher (run build-atlas.sh)" >&2; exit 1; }

"$PORT_DIR/transplant-session.sh" "${from_args[@]}"

mkdir -p "$shots"
port_start_display

run_pid=""
cleanup() {
	rm -f "$stop_file"
	[ -n "$run_pid" ] && kill "$run_pid" 2>/dev/null || true
	# SIGKILL, not SIGTERM: the launcher ignores SIGTERM, and an instance left
	# running keeps talking to the account (and holds the binary busy for the
	# next build)
	pkill -9 -f "^$launcher " 2>/dev/null || true
	[ -n "${PORT_XVFB_PID:-}" ] && kill "$PORT_XVFB_PID" 2>/dev/null || true
	return 0
}
trap cleanup EXIT

# Everything after this line in the log; the checks are sequential, so "did it
# happen yet" is always "is it in the log below the mark I took".
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

# Positions are per-mille of the ATLWindow, as in check-mtproto.sh.
click_at() {
	xdotool mousemove \
		"$((win_x + win_w * $1 / 1000))" \
		"$((win_y + win_h * $2 / 1000))" \
		sleep 0.2 click 1
}

echo "booting Mercurygram for up to ${seconds}s with the transplanted session"
: >"$log"
"$PORT_DIR/run.sh" --seconds "$seconds" --stop-file "$stop_file" \
	>"$PORT_OUT/check-messages.log" 2>&1 &
run_pid=$!

wait_for_log '^boot: main activity started' 90 || {
	echo "the app never reached the main activity:" >&2
	tail -40 "$log" >&2
	exit 1
}

# The account's own user id, which is also the id of the Saved Messages dialog.
# MediaDataController asks for these preferences by name at startup, so the log
# has it without anything here parsing the session.
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
# Two guards, because a stray click on the dialog list opens somebody's chat:
# the overflow menu has to visibly open before its third item is clicked, and
# the chat that opens has to be dialog $self_id before anything is typed.

opened=0
for attempt in $(seq 6); do
	port_screenshot "$shots/messages-chatlist.png"
	click_at 970 43
	sleep 2
	port_screenshot "$shots/messages-menu.png"
	if cmp -s "$shots/messages-chatlist.png" "$shots/messages-menu.png"; then
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
port_screenshot "$shots/messages-open.png"

# --- send --------------------------------------------------------------------

echo "typing '$text'"
click_at 417 935
sleep 1
xdotool type --delay 60 "$text"
sleep 2
port_screenshot "$shots/messages-typed.png"

echo "sending"
send_from=$(mark)
click_at 970 941

# inputPeerSelf serializes as all-zero ids: this is the proof that the message
# went to Saved Messages and not to a real correspondent.
wait_for_log 'send message user_id = 0 chat_id = 0 channel_id = 0' 30 "$send_from" || {
	echo "no messages.sendMessage to inputPeerSelf after the click" >&2
	tail -40 "$log" >&2
	exit 1
}
# The server's answer: updateMessageID carries the id the local message takes
# over, which is what turns the clock into a check mark.
wait_for_log '"TL_updateMessageID"' 60 "$send_from" || {
	echo "the server never acknowledged the message" >&2
	tail -60 "$log" >&2
	exit 1
}
wait_for_log 'process update TL_updateMessageID' 30 "$send_from" || {
	echo "updateMessageID came back but the app did not process it" >&2
	exit 1
}
sleep 3
port_screenshot "$shots/messages-sent.png"

# --- receive -----------------------------------------------------------------
# Back on the dialog list, because that is where a message for another chat
# shows up. The account's own traffic provides it; the update loop delivering
# it and the list redrawing is what the story asks for.

click_at 30 43
sleep 3
port_screenshot "$shots/messages-before-incoming.png"
incoming_from=$(mark)
echo "waiting up to ${incoming_seconds}s for an incoming message"
incoming=0
if wait_for_log 'process update TL_update(NewMessage|NewChannelMessage|ShortMessage|ShortChatMessage)' \
	"$incoming_seconds" "$incoming_from"; then
	incoming=1
fi
sleep 3
port_screenshot "$shots/messages-after-incoming.png"

# Everything driven is done.
touch "$stop_file"
echo "waiting for the run to finish"
status=0
wait "$run_pid" || status=$?
run_pid=""
[ "$status" = 0 ] || {
	echo "run.sh exited $status:" >&2
	cat "$PORT_OUT/check-messages.log" >&2
	exit 1
}

# --- verification ------------------------------------------------------------

log_text=$(cat "$log")

loaded=$(grep -oE "count=[0-9]+ for dialog  $self_id" <<<"$log_text" |
	grep -oE '[0-9]+' | head -1 || true)
[ "${loaded:-0}" -gt 0 ] || {
	echo "the chat opened but loaded no messages" >&2; exit 1; }

if grep -q 'UnsatisfiedLinkError' <<<"$log_text"; then
	echo "an UnsatisfiedLinkError appeared:" >&2
	grep -B 2 -A 8 'UnsatisfiedLinkError' <<<"$log_text" >&2
	exit 1
fi

# The message list has to have drawn something: a chat whose cells all failed
# to draw screenshots as the empty wallpaper (that is what the missing
# ViewStructure did, see BRINGUP_NOTES.md).
cmp -s "$shots/messages-chatlist.png" "$shots/messages-open.png" && {
	echo "the screen did not change when the chat opened" >&2; exit 1; }
cmp -s "$shots/messages-typed.png" "$shots/messages-sent.png" && {
	echo "the sent message never appeared in the list" >&2; exit 1; }

sent_id=$(grep -oE '"TL_updateMessageID"[^}]*"id":[0-9]+' <<<"$log_text" | grep -oE '[0-9]+$' | head -1 || true)
[ "${sent_id:-0}" -gt 0 ] || {
	echo "the server's answer carried no message id" >&2; exit 1; }

[ "$incoming" = 1 ] || {
	echo "no incoming message arrived within ${incoming_seconds}s" >&2
	echo "(this half of the check rides on the account's own traffic;" >&2
	echo " re-run with a longer --incoming-seconds)" >&2
	exit 1
}
cmp -s "$shots/messages-before-incoming.png" "$shots/messages-after-incoming.png" && {
	echo "an incoming message was processed but the dialog list did not redraw" >&2
	exit 1; }

echo
echo "message check passed:"
echo "  Saved Messages opened with $loaded messages from the cache and drew"
echo "  '$text' went out to inputPeerSelf and came back as message $sent_id"
echo "  an incoming message was processed and the dialog list redrew"
echo "  screenshots in $shots/messages-*.png"
exit 0
