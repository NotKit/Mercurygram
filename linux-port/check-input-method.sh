#!/bin/bash
# Checks that the app keeps the input method's copy of the editor in step.
#
# Maliit's server mirrors the focused editor -- surrounding text, cursor,
# anchor -- and its keyboard predicts from that mirror, so an edit the app makes
# without telling the input method leaves the keyboard completing a word that no
# longer exists. That is what resurrects text after a message is sent. There is
# no maliit server on a desktop, so this drives the real UI against the debug
# backend (ATL_IM_MODULE=debug) and reads the state the app pushed out of its
# trace (ATL_DEBUG_IME=1) -- the same state a real backend forwards over D-Bus.
#
# Boots the transplanted session and drives the UI with xdotool, exactly as
# check-messages.sh does, including its two guards: the overflow menu has to
# visibly open, and the chat that opens has to be dialog $self_id, before
# anything is typed. Saved Messages is the only chat this may write to.
#
# What it requires afterwards, in out/run.log:
#   focusing the field activated the context (update focus=1 focusChanged=1)
#     and asked for the panel
#   typing pushed the field's text as surroundingText, with the cursor at its
#     end -- the state the keyboard predicts from
#   sending the message pushed an *empty* surroundingText and reset the input
#     method, so nothing of the sent text survives in it
#   leaving the field released the context (update focus=0) and hid the panel
#
# Usage: linux-port/check-input-method.sh [--seconds N] [--from DIR]
#   --seconds  upper bound on the run; it ends as soon as the checks are done.
#              Default 900
#   --from     source data dir for the transplant
#
# Writes out/run.log and out/screenshots/im-*.png.
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
stop_file="$PORT_OUT/.input-method-done"
shots="$PORT_OUT/screenshots"
text="mg-im-$(date +%s)"

command -v xdotool >/dev/null || { echo "xdotool is required to drive the UI" >&2; exit 1; }
[ -x "$launcher" ] || { echo "no launcher at $launcher (run build-atlas.sh)" >&2; exit 1; }

# The debug backend stands in for maliit: it needs a non-zero inset to enable
# itself, and ATL_DEBUG_IME makes it print every state the app pushes. The inset
# is 1px on purpose -- a realistic one would move the composer up by a keyboard's
# height and the per-mille positions below (shared with check-messages.sh) would
# no longer land on it. What is under test here is the state protocol, not the
# resize.
export ATL_IM_MODULE=debug
export ATL_IM_DEBUG_INSET=1
export ATL_DEBUG_IME=1

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

# the trace printed after line $1, optionally stopping at line $2
since() {
	if [ -n "${2:-}" ]; then
		head -n "$2" "$log" 2>/dev/null | tail -n "+$1" | grep -E '^atl_ime: ' || true
	else
		tail -n "+$1" "$log" 2>/dev/null | grep -E '^atl_ime: ' || true
	fi
}

colours_in() {
	local png="$1" x="$2" y="$3" w="$4" h="$5"
	convert "$png" -crop \
		"$((win_w * w / 1000))x$((win_h * h / 1000))+$((win_w * x / 1000))+$((win_h * y / 1000))" \
		+repage -format %k info:
}

# Positions are per-mille of the ATLWindow, as in check-messages.sh.
click_at() {
	xdotool mousemove \
		"$((win_x + win_w * $1 / 1000))" \
		"$((win_y + win_h * $2 / 1000))" \
		sleep 0.2 click 1
}

echo "booting Mercurygram for up to ${seconds}s with the debug input method"
: >"$log"
"$PORT_DIR/run.sh" --seconds "$seconds" --stop-file "$stop_file" \
	>"$PORT_OUT/check-input-method.log" 2>&1 &
run_pid=$!

wait_for_log 'boot: main activity started' 90 || {
	echo "the app never reached the main activity:" >&2
	tail -40 "$log" >&2
	exit 1
}

# The backend is selected lazily, the first time app code touches
# InputMethodManager -- i.e. not before a field is focused. It is asserted after
# that, not here.

# The account's own user id, which is also the id of the Saved Messages dialog.
self_id=""
for _ in $(seq 120); do
	self_id=$(grep -oE 'getSharedPreferences\(ringtones_pref_[0-9]+\)' "$log" 2>/dev/null |
		grep -oE '[0-9]+' | grep -vx 0 | head -1 || true)
	[ -n "$self_id" ] && break
	sleep 0.5
done
[ -n "$self_id" ] || {
	echo "could not tell which account is logged in; refusing to type anything" >&2
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

# The composer can take focus while the chat is opening rather than on the click
# below, so the focus phase is everything from here to the first keystroke.
chat_from=$(mark)
opened=0
for attempt in $(seq 6); do
	port_screenshot "$shots/im-chatlist.png"
	click_at 970 43
	sleep 2
	port_screenshot "$shots/im-menu.png"
	if cmp -s "$shots/im-chatlist.png" "$shots/im-menu.png"; then
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
	echo "could not open Saved Messages; nothing was typed" >&2
	exit 1
}
sleep 4

# --- focus the field ---------------------------------------------------------

echo "focusing the message field"
click_at 417 935
sleep 2
port_screenshot "$shots/im-focused.png"

grep -q "input_method: using 'debug' backend" "$log" || {
	echo "the debug input method backend did not come up; nothing to observe" >&2
	tail -20 "$log" >&2
	exit 1
}

# --- type --------------------------------------------------------------------

echo "typing '$text'"
type_from=$(mark)
focus_trace=$(since "$chat_from" "$type_from")
xdotool type --delay 60 "$text"
sleep 2
port_screenshot "$shots/im-typed.png"
type_trace=$(since "$type_from")

# --- an emoji, i.e. a character outside the BMP ------------------------------
# JNI's "UTF-8" encodes those as a CESU-8 surrogate pair, which GLib rejects: a
# backend that passes GetStringUTFChars straight to g_variant_new_string drops
# surroundingText from the state (with a pile of GLib criticals) the moment one
# appears. Tapping one in and reading it back out of the trace is the check.
# Panel positions and the close loop are check-emoji.sh's.

echo "adding an emoji from the panel"
emoji_from=$(mark)
click_at 33 942
sleep 3
click_at 78 731
sleep 2
port_screenshot "$shots/im-emoji.png"
emoji_trace=$(since "$emoji_from")

# the action bar strip is only on screen when the panel is closed
action_bar=$(colours_in "$shots/im-typed.png" 0 0 1000 60)
closed=0
for attempt in $(seq 3); do
	click_at 33 19
	sleep 2
	port_screenshot "$shots/im-emoji-closed.png"
	if [ "$(colours_in "$shots/im-emoji-closed.png" 0 0 1000 60)" = "$action_bar" ]; then
		closed=1
		break
	fi
	echo "the emoji panel did not close (attempt $attempt)" >&2
done
[ "$closed" = 1 ] || {
	echo "the emoji panel stayed open; the send and back positions would be wrong" >&2
	exit 1
}

# --- send --------------------------------------------------------------------

echo "sending"
send_from=$(mark)
click_at 970 941
wait_for_log 'send message user_id = 0 chat_id = 0 channel_id = 0' 30 "$send_from" || {
	echo "no messages.sendMessage to inputPeerSelf after the click" >&2
	tail -40 "$log" >&2
	exit 1
}
sleep 3
port_screenshot "$shots/im-sent.png"
send_trace=$(since "$send_from")

# --- leave the field ---------------------------------------------------------

echo "leaving the chat"
leave_from=$(mark)
click_at 30 43
sleep 3
port_screenshot "$shots/im-left.png"
leave_trace=$(since "$leave_from")

touch "$stop_file"
echo "waiting for the run to finish"
status=0
wait "$run_pid" || status=$?
run_pid=""
[ "$status" = 0 ] || {
	echo "run.sh exited $status:" >&2
	cat "$PORT_OUT/check-input-method.log" >&2
	exit 1
}

# --- verification ------------------------------------------------------------

fail() { echo "FAIL: $1" >&2; echo "--- trace ---" >&2; echo "$2" >&2; exit 1; }

grep -qE 'update focus=1 focusChanged=1' <<<"$focus_trace" ||
	fail "focusing the field did not activate an input context" "$focus_trace"
grep -qE '^atl_ime: show$' <<<"$focus_trace" ||
	fail "focusing the field did not ask for the panel" "$focus_trace"

# The keyboard predicts from surroundingText: it has to carry what was typed,
# and the cursor has to sit at its end.
grep -qF "text='$text'" <<<"$type_trace" ||
	fail "the typed text never reached the input method as surroundingText" "$type_trace"
grep -qE "update focus=1 focusChanged=0 cursor=${#text} anchor=${#text} text='$text'" <<<"$type_trace" ||
	fail "the cursor pushed with the typed text is not at its end" "$type_trace"

# The pushed text has to still be valid UTF-8 after the emoji, and the emoji has
# to be in it.
emoji_line=$(grep -F "text='$text" <<<"$emoji_trace" | tail -1)
[ -n "$emoji_line" ] ||
	fail "no state was pushed after the emoji was tapped" "$emoji_trace"
grep -qP "text='\Q$text\E.*[^\x00-\x7f]" <<<"$emoji_line" ||
	fail "the emoji never reached the input method (line: $emoji_line)" "$emoji_trace"
iconv -f UTF-8 -t UTF-8 <<<"$emoji_line" >/dev/null 2>&1 ||
	fail "the state pushed after the emoji is not valid UTF-8 (modified UTF-8 leaked out of JNI)" "$emoji_trace"
grep -qE 'GLib-CRITICAL|requires valid UTF-8' "$log" &&
	fail "GLib rejected something the input method path handed it" "$(grep -E 'GLib-CRITICAL|valid UTF-8' "$log" | head -5)"

# The regression this check exists for: after the send, the input method must be
# told the field is empty, and its uncommitted text dropped. Leaving either out
# is what makes the keyboard put the sent word back.
grep -qE '^atl_ime: reset$' <<<"$send_trace" ||
	fail "sending the message did not reset the input method" "$send_trace"
grep -qE "update focus=1 [^ ]+ cursor=0 anchor=0 text=''" <<<"$send_trace" ||
	fail "sending the message left stale surrounding text in the input method" "$send_trace"
grep -qF "text='$text'" <<<"$send_trace" &&
	fail "the sent text was still being pushed after the send" "$send_trace"

grep -qE 'update focus=0' <<<"$leave_trace" ||
	fail "leaving the field did not release the input context" "$leave_trace"
grep -qE '^atl_ime: hide$' <<<"$leave_trace" ||
	fail "leaving the field did not hide the panel" "$leave_trace"

echo
echo "input method check passed:"
echo "  focusing the field activated the context and asked for the panel"
echo "  '$text' reached the input method as surroundingText, cursor at ${#text}"
echo "  the emoji survived as valid UTF-8: ${emoji_line#*text=}"
echo "  the send reset the input method and pushed an empty surrounding text"
echo "  leaving the field released the context and hid the panel"
echo "  screenshots in $shots/im-*.png"
exit 0
