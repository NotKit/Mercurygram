#!/bin/bash
# Checks that MTProto works on the port.
#
# Boots the app with run.sh and drives the real UI with xdotool:
# "Start Messaging" -> phone number -> next -> confirm, which is what makes the
# app send auth.sendCode. Then it checks out/run.log for tgnet's native init, a
# completed DC handshake within 30s of the login screen, and a server answer to
# auth.sendCode.
#
# A rejection is proof enough of the round trip: with the dummy API_KEYS the
# port builds with (APP_ID=0), every request that carries initConnection comes
# back 400 CONNECTION_API_ID_INVALID. Export APP_ID/APP_HASH and re-run
# build-classpath.sh for a build that can actually log in.
#
# Usage: linux-port/check-mtproto.sh [--phone NUMBER] [--seconds N]
#   --phone     number to type, country code first; default is a fake US one
#   --seconds   how long the app runs in total; default 90
#
# Writes out/run.log and out/screenshots/mtproto-*.png.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"
source "$PORT_DIR/launcher/display.sh"

phone="15551234567"
seconds=90

while [ $# -gt 0 ]; do
	case "$1" in
	--phone) phone="$2"; shift 2 ;;
	--seconds) seconds="$2"; shift 2 ;;
	*) echo "unknown option: $1" >&2; exit 1 ;;
	esac
done

# whatever $PORT_LAUNCHER selects, because the run below goes through run.sh
launcher="$PORT_LAUNCHER_BIN"
log="$PORT_OUT/run.log"
shots="$PORT_OUT/screenshots"

command -v xdotool >/dev/null || { echo "xdotool is required to drive the UI" >&2; exit 1; }
[ -x "$launcher" ] || { echo "no launcher at $launcher (run build-atlas.sh)" >&2; exit 1; }

mkdir -p "$shots"
port_start_display

run_pid=""
cleanup() {
	[ -n "$run_pid" ] && kill "$run_pid" 2>/dev/null || true
	# run.sh backgrounds the launcher, so killing run.sh alone would orphan it.
	# Anchored, so this matches the binary and not a shell that names it.
	pkill -f "^$launcher " 2>/dev/null || true
	# port_start_display's own EXIT trap is replaced by this one
	[ -n "${PORT_XVFB_PID:-}" ] && kill "$PORT_XVFB_PID" 2>/dev/null || true
	return 0
}
trap cleanup EXIT

# Waits for a line to appear in the log; returns 1 on timeout.
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

# Clicks inside the ATLWindow, positions given as per-mille of its size. The
# window is the whole 960x540 screen under Xvfb, but not on a real session.
click_at() {
	local fx="$1" fy="$2"
	xdotool mousemove \
		"$((win_x + win_w * fx / 1000))" \
		"$((win_y + win_h * fy / 1000))" \
		sleep 0.2 click 1
}

echo "booting Mercurygram for ${seconds}s, log in $log"
# run.sh truncates the log itself, but not before this script starts polling it:
# an old log would answer every wait_for_log instantly.
: >"$log"
"$PORT_DIR/run.sh" --seconds "$seconds" --fresh >"$PORT_OUT/check-mtproto.log" 2>&1 &
run_pid=$!

wait_for_log '^boot: main activity started' 90 || {
	echo "the app never reached the main activity:" >&2
	tail -40 "$log" >&2
	exit 1
}
login_screen_at=$(date +%s)
sleep 3

# xdotool exits 1 when nothing matches, and the window is mapped a moment after
# the activity starts, so keep asking for a few seconds.
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
port_screenshot "$shots/mtproto-intro.png"

echo "clicking Start Messaging"
click_at 500 874
sleep 3
port_screenshot "$shots/mtproto-login.png"

# --- DC connection ----------------------------------------------------------
# The clock starts at the login screen, as the story asks.
deadline=$((30 - ($(date +%s) - login_screen_at)))
wait_for_log 'handshake: completed' $((deadline > 1 ? deadline : 1)) || {
	echo "no completed DC handshake within 30s of the login screen" >&2
	exit 1
}
wait_for_log 'got response for request .*TL_help_getConfig' 10 || {
	echo "the handshake completed but help.getConfig got no answer" >&2
	exit 1
}
echo "DC connected $(( $(date +%s) - login_screen_at ))s after the login screen"

# --- auth.sendCode ----------------------------------------------------------

echo "typing +$phone"
xdotool type --delay 120 "$phone"
sleep 2
port_screenshot "$shots/mtproto-phone.png"

echo "submitting the number"
click_at 949 502
# The app asks "Is this the correct number?" before it sends anything; the log
# is what tells us whether that dialog is up, so only click Yes if it is. The
# line is ConnectionsManager.sendRequestInternal's "send request <object> with
# token = N", where <object> is TLObject's default toString.
if ! wait_for_log 'send request .*TL_auth_sendCode' 5; then
	port_screenshot "$shots/mtproto-confirm.png"
	click_at 934 343
fi

wait_for_log 'send request .*TL_auth_sendCode' 30 || {
	echo "auth.sendCode was never sent" >&2
	tail -40 "$log" >&2
	exit 1
}
sleep 3
port_screenshot "$shots/mtproto-sendcode.png"

echo "waiting for the run to finish"
status=0
wait "$run_pid" || status=$?
run_pid=""
[ "$status" = 0 ] || {
	echo "run.sh exited $status:" >&2
	cat "$PORT_OUT/check-mtproto.log" >&2
	exit 1
}

# --- verification -----------------------------------------------------------

log_text=$(cat "$log")

# tgnet's own init: the native ConnectionsManager starts its network thread and
# writes the account config before anything can be sent.
for expected in \
	"network thread started" \
	"config write ok" \
	"handshake: completed"
do
	grep -qF "$expected" <<<"$log_text" || {
		echo "run.log has no '$expected'" >&2; exit 1; }
done

if grep -q 'UnsatisfiedLinkError' <<<"$log_text"; then
	echo "an UnsatisfiedLinkError appeared:" >&2
	grep -B 2 -A 8 'UnsatisfiedLinkError' <<<"$log_text" >&2
	exit 1
fi

# The request going out is half of it; the server has to answer. A rejection
# counts, a code being sent counts, silence does not. Both arms are the app's own
# ConnectionsManager logging, not the TL dumper's JSON, which the port turns off
# -- and deliberately not tgnet's native "got response for request %s"
# line either: that %s is typeid(*request->rawRequest).name(), and
# TgNetWrapper.cpp:111 wraps every request coming from Java in a TL_api_request,
# so no Java request type can ever appear in it. (help.getConfig above is tgnet's
# own C++ object, which is why the same shape works there.)
answer=$(grep -oE 'TL_auth_sendCode@[0-9a-f]+ got error [0-9]+ [A-Z_0-9]+' <<<"$log_text" | head -1 || true)
if [ -z "$answer" ]; then
	# The success arm, untested here: with the dummy APP_ID the server always
	# rejects, so only the error arm above ever runs in this environment.
	# ConnectionsManager.java:445 logs "java received " + the deserialised
	# response; auth.sendCode deserialises its own with
	# TL_auth_sentCode.TLdeserialize (TLRPC.java:51020), whose three results are
	# TL_auth_sentCode, TL_auth_sentCodeSuccess and TL_auth_sentCodePaymentRequired.
	# Only auth.resendCode shares that response type, and this check never sends
	# one -- that needs the code screen.
	grep -qE 'java received .*TL_auth_sentCode' <<<"$log_text" || {
		echo "auth.sendCode got no answer from the server" >&2
		grep -A 6 'TL_auth_sendCode' <<<"$log_text" | head -30 >&2
		exit 1; }
	answer="a code was sent"
fi

echo
echo "MTProto check passed:"
echo "  tgnet native init, DC handshake and help.getConfig all completed"
echo "  auth.sendCode round trip: $answer"
echo "  screenshots in $shots/mtproto-*.png"
if grep -q 'CONNECTION_API_ID_INVALID' <<<"$log_text"; then
	echo
	echo "note: this build carries APP_ID=0 (dummy API_KEYS), so the server"
	echo "      rejects every request that opens a connection. The round trip is"
	echo "      real, login is not possible: export APP_ID/APP_HASH and re-run"
	echo "      build-classpath.sh before transplanting a session."
fi
exit 0
