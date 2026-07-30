#!/bin/bash
# Shared helper for the port scripts that run the launcher: the ATLWindow needs
# somewhere to go, and this box may have no session at all. Source it:
#
#   source "$PORT_DIR/launcher/display.sh"
#   port_start_display     # exports DISPLAY, starting an Xvfb if there is none
#   port_screenshot FILE   # best effort, never fails the caller

# Starts an Xvfb when the session has neither Wayland nor X, and kills it again
# on exit. Sets a trap on EXIT, so call it before the caller sets its own.
port_start_display() {
	if [ -n "${WAYLAND_DISPLAY:-}" ] || [ -n "${DISPLAY:-}" ]; then
		return 0
	fi

	command -v Xvfb >/dev/null || { echo "no display and no Xvfb to make one" >&2; return 1; }

	local display xvfb_pid=""
	for display in $(seq 90 99); do
		Xvfb ":$display" -screen 0 960x540x24 >/dev/null 2>&1 &
		xvfb_pid=$!
		sleep 1
		if kill -0 "$xvfb_pid" 2>/dev/null; then
			export DISPLAY=":$display"
			break
		fi
		xvfb_pid=""
	done
	[ -n "$xvfb_pid" ] || { echo "could not start Xvfb" >&2; return 1; }

	trap 'kill '"$xvfb_pid"' 2>/dev/null || true' EXIT
	echo "started Xvfb on $DISPLAY"
}

# Screenshots the whole screen; a missing tool is not an error, the caller
# decides whether it needed the picture.
port_screenshot() {
	local out="$1"
	if [ -n "${WAYLAND_DISPLAY:-}" ] && command -v grim >/dev/null; then
		grim "$out" && return 0
	elif [ -n "${DISPLAY:-}" ] && command -v import >/dev/null; then
		import -window root "$out" && return 0
	fi
	echo "note: no screenshot tool for this session, skipping the screenshot"
	return 0
}
